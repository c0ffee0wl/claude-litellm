# claude-litellm

Local Linux setup that routes **Claude Code** through **[LiteLLM](https://docs.litellm.ai/)** as an Anthropic-compatible gateway to Azure OpenAI, Vertex Gemini, and other providers.

Runs on Debian (Bash) and Kali (zsh or Bash) as a regular user. No WSL ties, no auto-updater, no supply-chain hardening configs (handle that outside this repo).

## Quick Start

```bash
git clone https://github.com/c0ffee0wl/claude-litellm ~/claude-litellm
cd ~/claude-litellm
cp .env.example .env
nano .env                     # optional: fill AZURE_OPENAI_API_KEY + AZURE_RESOURCE_ENDPOINT
./linux/setup.sh
source ~/.profile             # load ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN
```

Now run `claude`. Traffic goes to `http://127.0.0.1:4000` (LiteLLM's unified Anthropic `/v1/messages` endpoint), which translates to Azure OpenAI underneath.

**No Azure account? Skip the `.env` Azure section.** Setup still finishes (Postgres + LiteLLM + UI all come up), but Claude Code starts with no default model. The banner at the end of `setup.sh` covers it:

1. Open <http://127.0.0.1:4000/ui> (user `admin`, password is the `ANTHROPIC_AUTH_TOKEN` from `~/.profile`) and add a working model.
2. Edit `~/.profile` and point `ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL` at the Public Model Name you just added. One name works for all three.
3. `source ~/.profile` before running `claude`.

**If you fill in Azure**: the baseline `linux/configs/litellm-config.yaml` assumes Azure deployments named exactly `gpt-5.4` and `gpt-5.4-mini`. If yours differ, edit the YAML before running setup.

## Setup Modes

| Command | What happens |
|---|---|
| `./linux/setup.sh` | Full setup: LiteLLM + Claude Code + managed-settings hardening + ACP + claude-devtools |
| `./linux/setup.sh --router-only` | LiteLLM + Claude Code + claude-devtools. Skips ACP and managed-settings hardening. Dev-box mode |
| `./linux/setup.sh --harden-only` | Claude Code + managed-settings only. Skips LiteLLM stack. Use when LiteLLM runs on another host |
| `./linux/setup.sh --yes` | Non-interactive (combine with any of the above) |

## Architecture

```
Claude Code  ──►  http://127.0.0.1:4000 (LiteLLM /v1/messages)  ──►  Azure OpenAI
                          │
                          └──► (optional) Vertex AI Gemini, other providers
```

- **LiteLLM** runs as a systemd user service on port 4000 (LiteLLM's default).
- **Model naming**: Claude Code asks for the upstream id directly (`azure/gpt-5.4` for Sonnet/Opus, `azure/gpt-5.4-mini` for Haiku) via `ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL` in `~/.profile`. LiteLLM's `model_list` supplies the Azure endpoint + key but adds no alias layer. Anthropic's `/v1/messages` format is preserved end-to-end.
- **Model discovery**: `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` is left on so any `claude-*` / `anthropic-*`-named entry added later via the LiteLLM `/ui` auto-appears in `/model`. The baseline upstream-named entries are reachable but not listed there (the discovery filter only surfaces names matching that prefix); use `/model azure/gpt-5.4-mini` to switch.
- **Auth**: a `sk-…` master key is auto-generated on first run, stored in `~/.config/litellm/env` (mode 600) and in `~/.profile` as `ANTHROPIC_AUTH_TOKEN`.
- **Observability**: bundled LiteLLM admin UI at `http://127.0.0.1:4000/ui/` (degraded read-only without a backing Postgres).
- **Session inspection**: [claude-devtools](https://github.com/matt1398/claude-devtools) standalone web UI at `http://127.0.0.1:12002` (pinned to the upstream's latest release tag; built locally with bun, no Electron).

## Important Files

- `linux/configs/litellm-config.yaml`: model_list, retries, master-key reference, commented guardrails block
- `linux/configs/claude-managed-settings.json`: sandbox, permissions, telemetry opt-outs, bash guard hooks
- `linux/setup.sh`: phases 0-11 (see `CLAUDE.md`)
- `.env`: API keys (gitignored; create from `.env.example`)

## Future Work

- **Guardrails**: LiteLLM ships free OSS guardrails (`litellm_content_filter` for regex-based PII redaction, `hide-secrets`, Presidio for ML-based PII/PHI). A commented example block is in `linux/configs/litellm-config.yaml`; uncomment to enable.
- **Spend tracking / virtual keys / persistent logs**: requires Postgres. Set `DATABASE_URL` in the env file and uncomment the `general_settings.database_url` line.

## Idempotency

`setup.sh` is idempotent and uses **install-if-missing-only**: if uv, bun, LiteLLM, Claude Code, or ACP are already present, they are not touched (no auto-update). Updates are managed by the user (`uv tool upgrade litellm`, `claude update`, etc.).

# claude-litellm

Local Linux setup that routes **Claude Code** through **[LiteLLM](https://docs.litellm.ai/)** as an Anthropic-compatible gateway to Azure, Vertex Gemini, and other providers.

Runs on Debian (Bash) and Kali (zsh or Bash) as a regular user. No WSL ties, no supply-chain hardening configs (handle that outside this repo).

## Quick Start

**Before you run**: the baseline `linux/configs/litellm-config.yaml` expects Azure deployments named exactly `gpt-5.6-terra` (Sonnet + Opus) and `gpt-5.6-luna` (Haiku), plus an optional `gpt-5.6-sol` flagship — served, but never a Claude Code default, so skipping it only costs you `/model azure/gpt-5.6-sol`. If your names differ, edit that YAML first. No Azure account at all? See below; setup still finishes.

```bash
cd ~
git clone https://github.com/c0ffee0wl/claude-litellm 
cd claude-litellm
cp .env.example .env
nano .env                     # optional: fill AZURE_OPENAI_API_KEY + AZURE_RESOURCE_ENDPOINT
./linux/setup.sh
source ~/.profile             # load ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN
curl -sf http://127.0.0.1:4000/health/liveliness && echo "gateway up"
```

Now run `claude`. Traffic goes to `http://127.0.0.1:4000` (LiteLLM's unified Anthropic `/v1/messages` endpoint), which translates to Azure underneath.

**No Azure account? Skip the `.env` Azure section.** Setup still finishes (Postgres + LiteLLM + UI all come up), but Claude Code starts with no default model. The banner at the end of `setup.sh` walks you through the fix: add a model in the LiteLLM UI (URL and login under [Architecture](#architecture)), point the three `ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL` vars at its Public Model Name, declare that name's `_SUPPORTED_CAPABILITIES` — skip this and Claude Code leaves thinking and effort off — then `source ~/.profile`.

## Setup Modes

| Command | What happens |
|---|---|
| `./linux/setup.sh` | Full setup: LiteLLM + Claude Code + managed-settings hardening + `nah` plugin + claude-devtools |
| `./linux/setup.sh --router-only` | LiteLLM + Claude Code + claude-devtools, without the policy layer: skips managed-settings hardening and the `nah` plugin, and ships the sandbox off. Dev-box mode |
| `./linux/setup.sh --harden-only` | Claude Code + managed-settings + `nah` plugin only. Skips LiteLLM and claude-devtools. Use when LiteLLM runs on another host |
| `./linux/setup.sh --install-only` | Claude Code + claude-devtools + the hardening/telemetry env vars only. Skips LiteLLM, Postgres, managed-settings, the `nah` plugin, **and all gateway wiring** — Claude Code talks to the real Anthropic API until you point it at a router yourself. Sandbox off |
| `./linux/setup.sh --install-obsidian` | Also installs the ACP adapter + the latest Obsidian (`.deb`) |
| `./linux/setup.sh --docker` | Runs LiteLLM as a rootless Docker Compose service instead of the native `uv` install (Postgres stays on the host, so `/ui` data survives the switch) |

`--router-only`, `--harden-only`, and `--install-only` are mutually exclusive. `--install-obsidian` and `--docker` are additive on top of any of them, except that `--docker` needs a LiteLLM to containerize, so it can't pair with `--harden-only`/`--install-only`.

"Sandbox off" means the `sandbox` block still ships in user settings with `enabled:false` — the credential and network floor stays pre-configured, and bwrap is installed in every mode, so flipping it to `true` or running `/sandbox` activates it. This applies to fresh installs only; an existing `~/.claude/settings.json` is never rewritten.

## Architecture

```
Claude Code  ──►  http://127.0.0.1:4000 (LiteLLM /v1/messages)  ──►  Azure
                          │
                          └──► (optional) Vertex AI Gemini, other providers
```

- **LiteLLM** runs as a systemd user service on port 4000 (LiteLLM's default).
- **Model naming**: Claude Code asks for the upstream id directly (`azure/gpt-5.6-terra` for Sonnet/Opus, `azure/gpt-5.6-luna` for Haiku) via `ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL` in `~/.profile`. LiteLLM's `model_list` supplies the Azure endpoint + key but adds no alias layer, and targets Azure's v1 surface (`…/openai/v1`) so every request goes out through the Responses API. Anthropic's `/v1/messages` format stays intact the whole way.
- **Model discovery**: `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` is left on so any `claude-*` / `anthropic-*`-named entry added later via the LiteLLM `/ui` auto-appears in `/model`. The baseline upstream-named entries are reachable but not listed there, since the filter only surfaces names matching that prefix — type the full id to switch (`/model azure/gpt-5.6-luna`). `.env.example` has the rationale and the upstream doc link.
- **Auth**: a `sk-…` master key is auto-generated on first run, stored in `~/.config/litellm/env` (mode 600) and in `~/.profile` as `ANTHROPIC_AUTH_TOKEN`.
- **Observability**: bundled LiteLLM admin UI at <http://127.0.0.1:4000/ui/> — log in as `admin` with the `ANTHROPIC_AUTH_TOKEN` from `~/.profile`. Backed by the Postgres instance Phase 6 provisions, so spend tracking, virtual keys, persistent logs, and `/ui` model management are all on by default.
- **Session inspection**: [claude-devtools](https://github.com/matt1398/claude-devtools) standalone web UI at `http://127.0.0.1:12002` (pinned to the upstream's latest release tag; built locally with pnpm, run with bun, no Electron).
- **Sandboxed wrapper**: [blaude](https://github.com/c0ffee0wl/blaude) at `~/.local/bin/blaude` (installed/refreshed in every mode) runs Claude Code inside a bubblewrap sandbox for autonomous `--dangerously-skip-permissions` use. No `claude` alias is set — invoking it stays opt-in.
- **Action-aware safety guard**: [nah](https://github.com/manuelschipper/nah) installed as a Claude Code plugin (full + `--harden-only`). Classifies commands into action types and adds an independent `allow`/`ask`/`block` gate alongside the `claude-managed-settings.json` denies, catching wrapper-evasion the regex denies miss (`bash -c "rm -rf …"`, `python -c`, `git push -f`, …). Both layers fire independently, and a hook `"allow"` cannot override `deny[]`. **It survives `--dangerously-skip-permissions`** — that flag skips the prompt and the deny/ask/allow rules, but PreToolUse hooks run *before* the prompt, so under it `nah` is the only policy layer still active. See [CLAUDE.md](CLAUDE.md) for the caveats (no `.nah.yaml` tuning, unpinned marketplace, known interaction bugs).

## Important Files

- `linux/configs/litellm-config.yaml`: model_list, retries, master-key reference, commented guardrails block
- `linux/configs/claude-managed-settings.json`: permissions (deny/allow), telemetry opt-outs, bash guard hooks (root-enforced)
- `linux/configs/claude-settings.json`: user-scope `~/.claude/settings.json` template with statusLine and the `sandbox` block — `enabled:true` by default, user-toggleable via `/sandbox`, and shipped `false` by the modes noted above
- `linux/setup.sh`: phases 0-11 (see [CLAUDE.md](CLAUDE.md) for the full phase breakdown, key conventions, and troubleshooting)
- `.env`: API keys (gitignored; create from `.env.example`)

## Future Work

- **Guardrails**: LiteLLM ships free OSS guardrails (`litellm_content_filter` for regex-based PII redaction, `hide-secrets`, Presidio for ML-based PII/PHI). A commented example block is in `linux/configs/litellm-config.yaml`; uncomment to enable.

## Idempotency

`setup.sh` is idempotent and cheap to re-run: when nothing changed, it skips the apt round-trip and leaves both `~/.profile` and the running LiteLLM service untouched (the service only restarts on a config/env/unit/binary change). bun, uv, LiteLLM, and Claude Code are **upgraded in place** on every run, and `blaude` is re-fetched from its `main` branch (a rolling script with no releases). Everything else is **install-if-missing** and pinned artifacts only advance deliberately — see [CLAUDE.md](CLAUDE.md) > Key Conventions for the full policy.

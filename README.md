# claude-litellm

Local Linux setup that routes **Claude Code** through **[LiteLLM](https://docs.litellm.ai/)** as an Anthropic-compatible gateway to Azure, Vertex Gemini, and other providers.

It runs on Debian (Bash) and Kali (zsh or Bash) as a regular user. There are no WSL ties, and it ships no supply-chain hardening configs; handle those outside this repo.

## Quick start

**Before you run**: the baseline `linux/configs/litellm-config.yaml` expects Azure deployments named exactly `gpt-5.6-terra` (Sonnet and Opus) and `gpt-5.6-luna` (Haiku). A third deployment, `gpt-5.6-sol`, is optional: LiteLLM serves it, but Claude Code never selects it on its own, so skipping it costs you nothing beyond `/model azure/gpt-5.6-sol`. If your deployment names differ, edit that YAML first. If you have no Azure account, setup still finishes; see below.

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

**No Azure account? Skip the `.env` Azure section.** Setup still finishes and Postgres, LiteLLM, and the UI all come up, but Claude Code starts with no default model. The banner at the end of `setup.sh` walks you through the fix. Add a model in the LiteLLM UI (the URL and login are under [Architecture](#architecture)), point the three `ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL` vars at its Public Model Name, then `source ~/.profile`. Thinking and effort need no extra declarations: Claude Code sends adaptive thinking to model ids it doesn't recognize, and setup writes `CLAUDE_CODE_ALWAYS_ENABLE_EFFORT=1` to cover effort.

## Setup modes

| Command | What happens |
|---|---|
| `./linux/setup.sh` | Full setup: LiteLLM + Claude Code + managed-settings hardening + `nah` plugin + claude-devtools |
| `./linux/setup.sh --router-only` | LiteLLM + Claude Code + claude-devtools, without the policy layer: skips managed-settings hardening and the `nah` plugin, and ships the sandbox off. Dev-box mode |
| `./linux/setup.sh --harden-only` | Claude Code + managed-settings + `nah` plugin only. Skips LiteLLM and claude-devtools. Use when LiteLLM runs on another host |
| `./linux/setup.sh --install-only` | Claude Code + claude-devtools + the hardening/telemetry env vars only. Skips LiteLLM, Postgres, managed-settings, the `nah` plugin, **and all gateway wiring**, so Claude Code talks to the real Anthropic API until you point it at a router yourself. Sandbox off |
| `./linux/setup.sh --install-obsidian` | Also installs the ACP adapter + the latest Obsidian (`.deb`) |
| `./linux/setup.sh --docker` | Runs LiteLLM as a rootless Docker Compose service instead of the native `uv` install (Postgres stays on the host, so `/ui` data survives the switch) |

`--router-only`, `--harden-only`, and `--install-only` are mutually exclusive. `--install-obsidian` and `--docker` are additive on top of any of them, except that `--docker` needs a LiteLLM to containerize, so it cannot pair with `--harden-only` or `--install-only`.

"Sandbox off" means the `sandbox` block still ships in user settings with `enabled:false`, so the credential and network floor stays pre-configured. bwrap is installed in every mode, so flipping that value to `true` or running `/sandbox` activates it. This applies to fresh installs only; setup never rewrites an existing `~/.claude/settings.json`.

## Architecture

```
Claude Code  ──►  http://127.0.0.1:4000 (LiteLLM /v1/messages)  ──►  Azure
                          │
                          └──► (optional) Vertex AI Gemini, other providers
```

- **LiteLLM** runs as a systemd user service on port 4000 (LiteLLM's default).
- **Model naming**: Claude Code asks for the upstream id directly (`azure/gpt-5.6-terra` for Sonnet/Opus, `azure/gpt-5.6-luna` for Haiku) via `ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL` in `~/.profile`. LiteLLM's `model_list` supplies the Azure endpoint and key but adds no alias layer, and it targets Azure's v1 surface (`…/openai/v1`) so every request goes out through the Responses API. Anthropic's `/v1/messages` format stays intact the whole way.
- **Model discovery**: `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` is on, so a `claude-*` or `anthropic-*`-named entry added later via the LiteLLM `/ui` appears in `/model` automatically — once the installed LiteLLM is 1.95.0 or newer. The baseline upstream-named entries are reachable but never listed there, since the filter only surfaces names matching that prefix. Type the full id to switch (`/model azure/gpt-5.6-luna`). `.env.example` has the rationale and the upstream doc link.
- **Auth**: a `sk-…` master key is auto-generated on first run, stored in `~/.config/litellm/env` (mode 600) and in `~/.profile` as `ANTHROPIC_AUTH_TOKEN`.
- **Observability**: bundled LiteLLM admin UI at <http://127.0.0.1:4000/ui/>. Log in as `admin` with the `ANTHROPIC_AUTH_TOKEN` from `~/.profile`. It is backed by the Postgres instance Phase 6 provisions, so spend tracking, virtual keys, persistent logs, and `/ui` model management are all on by default.
- **Session inspection**: [claude-devtools](https://github.com/matt1398/claude-devtools) standalone web UI at `http://127.0.0.1:12002`, pinned to the upstream's latest release tag and built locally with pnpm, run with bun, without Electron.
- **Sandboxed wrapper**: [blaude](https://github.com/c0ffee0wl/blaude) at `~/.local/bin/blaude` (installed and refreshed in every mode) runs Claude Code inside a bubblewrap sandbox for autonomous `--dangerously-skip-permissions` use. Setup sets no `claude` alias, so invoking it stays opt-in.
- **Action-aware safety guard**: [nah](https://github.com/manuelschipper/nah) is installed as a Claude Code plugin in full and `--harden-only` modes. It classifies commands into action types and adds an independent `allow`/`ask`/`block` gate alongside the `claude-managed-settings.json` denies, which catches the wrapper-evasion those regex denies miss (`bash -c "rm -rf …"`, `python -c`, `git push -f`). Both layers fire independently, and a hook `"allow"` cannot override `deny[]`. It also survives `--dangerously-skip-permissions`: that flag skips the prompt and the deny/ask/allow rules, but PreToolUse hooks run before the prompt, so `nah` is the only policy layer still active under it. See [CLAUDE.md](CLAUDE.md) for the caveats, including the absent `.nah.yaml` tuning, the unpinned marketplace, and known interaction bugs.

## Important files

- `linux/configs/litellm-config.yaml`: model_list, retries, master-key reference, commented guardrails block
- `linux/configs/claude-managed-settings.json`: permissions (deny/allow), telemetry opt-outs, the bash guard hook (root-enforced)
- `linux/configs/claude-settings.json`: user-scope `~/.claude/settings.json` template with statusLine and the `sandbox` block. It is `enabled:true` by default, toggleable via `/sandbox`, and shipped as `false` by the modes noted above
- `linux/setup.sh`: phases 0-11 (see [CLAUDE.md](CLAUDE.md) for the full phase breakdown, key conventions, and troubleshooting)
- `.env`: API keys (gitignored; create from `.env.example`)

## Future work

- **Guardrails**: LiteLLM ships free OSS guardrails (`litellm_content_filter` for regex-based PII redaction, `hide-secrets`, Presidio for ML-based PII/PHI). A commented example block is in `linux/configs/litellm-config.yaml`; uncomment to enable.

## Idempotency

`setup.sh` is idempotent and cheap to re-run: when nothing changed, it skips the apt round-trip and leaves both `~/.profile` and the running LiteLLM service untouched (the service only restarts on a config, env, unit, or binary change). bun, uv, LiteLLM, and Claude Code are **upgraded in place** on every run, and `blaude` is re-fetched from its `main` branch, since it is a rolling script with no releases. Everything else is **install-if-missing**, and pinned artifacts only advance deliberately. See [CLAUDE.md](CLAUDE.md) > Key Conventions for the full policy.

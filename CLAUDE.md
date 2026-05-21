# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

claude-litellm is a Linux-side setup repo that installs and configures the [LiteLLM Proxy](https://docs.litellm.ai/) AI gateway as a systemd user service on `127.0.0.1:4000`, plus optionally Claude Code with managed settings. LiteLLM speaks Anthropic's Messages format natively on `/v1/messages` and translates to Azure OpenAI / Vertex Gemini / etc. via `model_list` entries.

There is no build system, test suite, or linter — this is a deployment automation repo of Bash scripts plus YAML/JSON configs.

## Architecture

Single execution context: Linux. Runs as the current `$USER` (no devuser, no sudo for the script itself; `sudo` is invoked only for `apt`, `loginctl enable-linger`, and writing `/etc/claude-code/managed-settings.json`).

Entry point: `linux/setup.sh`. It sources `linux/common.sh` for utilities and runs ten phases. Key flags (mutually exclusive; not persisted across reruns):
- `--router-only` skips Phase 4d (ACP install) and Phase 8a–8b (system-level: managed-settings.json sudo-install + `/tmp/claude` sandbox prereq). User-level Phase 8c–8d (`~/.claude/settings.json` statusLine, `~/.claude/statusline.sh`) still run. LiteLLM + Claude Code + claude-history + claude-devtools all install locally — useful for a dev box where you want to route through LiteLLM without system-level policy enforcement.
- `--harden-only` is the inverse: skips Phases 4a (LiteLLM), 4b (claude-run), 4d (ACP), Phase 5b (provider-secret collection), Phase 6 (Postgres + LiteLLM env file), Phase 7 (`litellm.service`), Phase 9 (`claude-history.service`), and Phase 10 (`claude-devtools.service`). Phase 5a's `~/.profile` writes still run. Installs only Claude Code + managed-settings — useful when LiteLLM runs on another host. To point at a remote router, set `ANTHROPIC_GATEWAY_URL=http://<remote>:4000` in `.env` before running — `set -a` sourcing lets `.env` override the localhost default, which then lands in `~/.profile` as `ANTHROPIC_BASE_URL`.

API keys come from `.env` in the repo root (gitignored; create from `.env.example`) — or from any provider env var you happen to have exported in your shell / `~/.profile`. `.env` is optional: if it's missing, Phase 5 logs a warning and continues, picking up whatever is already exported. `setup.sh` Phase 5 auto-discovers them via `collect_litellm_provider_vars` in `common.sh` (pattern `*_API_{KEY,BASE,VERSION,TOKEN}` plus a named list for AWS/GCP/watsonx/Azure-AD/OpenAI-org/HF extras) and writes the matches plus the LiteLLM master key + DB URL **only** to `~/.config/litellm/env` (the systemd EnvironmentFile, mode 600). The user's `~/.profile` gets only the gateway URL, the master key as `ANTHROPIC_AUTH_TOKEN`, and telemetry opt-outs — no upstream provider secrets.

LiteLLM speaks Anthropic on `/v1/messages` (the unified endpoint, not the `/anthropic/*` pass-through). Claude Code is configured via `ANTHROPIC_BASE_URL=http://127.0.0.1:4000` (no path suffix).

## Setup Phases (`linux/setup.sh`)

| Phase | What |
|---|---|
| 0 | self-update: `git pull --ff-only` and re-exec if behind. Skipped if `claude`/ACP is running or not a git checkout. |
| 1 | shell profile setup: ensure `~/.profile` and the `~/.bash_profile` shim sourcing it exist |
| 2 | apt: `git curl jq ca-certificates unzip rsync` (+ `bubblewrap socat` in full mode) |
| 3 | Install bun + uv (install-if-missing-only); symlink `node→bun`, `npx→bunx` |
| 4a | LiteLLM via `uv tool install litellm` (with `--with 'litellm[proxy]>=1.83.0,!=1.82.7,!=1.82.8'` — those PyPI versions were compromised) → `~/.local/bin/litellm` (install-if-missing) |
| 4b | claude-run via `bun add -g` (install-if-missing) |
| 4c | Claude Code via official curl-pipe installer (install-if-missing); always runs |
| 4d | (full only) ACP adapter via `bun add -g` (install-if-missing) |
| 5a | gateway URL + master key (as `ANTHROPIC_AUTH_TOKEN`) + telemetry opt-outs + `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` + `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY` + `ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL` → `~/.profile` (kept here, not managed-settings, so user can `unset` for `--dangerously-skip-permissions` and so `--router-only` gets them without root). The three default-model vars resolve to `azure/gpt-5.4{,-mini}` when both `AZURE_OPENAI_API_KEY` and `AZURE_RESOURCE_ENDPOINT` are set in `.env`; otherwise they're written empty (any prior non-empty value in `~/.profile` is preserved across re-runs) and a yellow end-of-script banner instructs the user to add a model via `/ui` and fill them in. Also scrubs `IS_DEMO` from `~/.profile` + current shell (anthropics/claude-code#37780) |
| 5b | provider secrets from `.env`/shell/`~/.profile` + master key → in-memory `LITELLM_ENV_CONTENT` (written to disk in Phase 6). Uses `collect_litellm_provider_vars` |
| 6 | Postgres + LiteLLM env file: apt-install `postgresql`; create role + db idempotently (skipped if `DATABASE_URL` set externally in `.env`); resolve `LITELLM_DB_PASSWORD` (reused across reruns, else `openssl rand -hex 24`); append `DATABASE_URL` / `STORE_MODEL_IN_DB=True` / `LITELLM_DB_PASSWORD` to the in-memory env content from 5b and write `~/.config/litellm/env` atomically (mode 600). Enables GUI model management via `/ui` |
| 7 | Deploy `litellm-config.yaml` to `~/.config/litellm/`; install + start `litellm.service`. LiteLLM auto-runs Prisma migrations on first boot |
| 8a–8b | (skipped under `--router-only`) Token-substitute managed-settings → `/etc/claude-code/managed-settings.json` (sudo); create `/tmp/claude` sandbox prereq |
| 8c–8d | User-level Claude Code state (runs in every mode): `~/.claude/settings.json` (statusLine — only deployed on a fresh install, never clobbered on re-runs), `~/.claude/statusline.sh` |
| 9 | Install + start `claude-history.service` (UI on port 12001) |
| 10 | Clone `matt1398/claude-devtools` to `~/.local/share/claude-devtools`, pin to latest release tag, bun-build standalone bundle, install + start `claude-devtools.service` on port 12002. Build failures are non-fatal — any existing build keeps serving. Skipped under `--harden-only`. |
| 11 | `apt autoremove` |

## Key Conventions

- **Idempotency**: every phase is safe to re-run.
- **install-if-missing-only**: if a tool is already present, don't reinstall and don't auto-update. The user manages tool versions externally (`uv tool upgrade litellm`, `claude update`, etc.).
- **Profile management**: use `update_profile_export` in `common.sh` for env-var changes — it writes to all `PROFILE_FILES` (just `~/.profile` by default). Never edit profile files with raw `sed`/`echo`. Never write provider secrets here — they belong in `~/.config/litellm/env`.
- **systemd template substitution**: service files in `linux/systemd/` use `__PLACEHOLDER__` tokens (`__LITELLM_BIN__`, `__APP_DIR__`, `__PORT__`, `__ENV_FILE__`, `__PATH__`). `deploy_user_systemd_service` in `common.sh` runs `sed` over them before `write_if_changed`.
- **Master-key strategy**: a `sk-<48 hex chars>` master key is auto-generated on first run via `openssl rand -hex 24`, written to `~/.config/litellm/env` (as `LITELLM_MASTER_KEY`) and to `~/.profile` (as `ANTHROPIC_AUTH_TOKEN`). Both names point at the same value. Re-runs preserve it via `read_profile_export`. Setting `ANTHROPIC_AUTH_TOKEN=sk-…` in `.env` overrides auto-generation.
- **Model naming**: the baseline `litellm-config.yaml` deliberately uses upstream provider-prefixed ids as Public Model Names (`azure/gpt-5.4`, `azure/gpt-5.4-mini`) — no `claude-*` alias layer. Claude Code asks for those ids directly via `ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL` in `~/.profile`. Trade-offs accepted by this choice:
  - **Gateway-discovery picker auto-population is off** for the baseline entries. Claude Code's `/v1/models` discovery filters on names starting with `claude` or `anthropic` (see <https://code.claude.com/docs/en/llm-gateway>); upstream-prefixed names don't match. The entries still route fine — Claude Code just won't list them in `/model`. Typing `/model azure/gpt-5.4-mini` still works.
  - **Hardcoded Anthropic-shaped feature gates may turn off** (1M context, reasoning-effort control). Empirical — there's no published list. Watch for unexpected token truncation.
  - **To get auto-discovery back for a UI-added model**, give it a `claude-*` or `anthropic-*` Public Model Name (e.g. `claude-gemini-3-pro` → `gemini/gemini-3.0-pro`, key `os.environ/GEMINI_API_KEY`). `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1` is left on in `~/.profile` so such an entry appears in `/model` automatically.
  - **Escape hatch for single-name picker entries**: set `ANTHROPIC_CUSTOM_MODEL_OPTION=<name>` (plus optional `…_NAME` / `…_DESCRIPTION`) in `claude-managed-settings.json`'s `env:` block. Adds one custom picker entry regardless of name shape — useful for pinning the headline upstream id in the picker.
  - **No-Azure install path**: leaving `AZURE_OPENAI_API_KEY` / `AZURE_RESOURCE_ENDPOINT` blank in `.env` (or omitting `.env` entirely) is supported — setup still completes, the three `ANTHROPIC_DEFAULT_*_MODEL` exports in `~/.profile` are written empty (Phase 5a; see also the Azure section in `.env.example`), and a banner at the end of `setup.sh` tells the user to add a model via `http://127.0.0.1:4000/ui` and set the vars manually. Re-runs preserve any non-empty value already in `~/.profile`.
- **Managed-settings token substitution**: `linux/configs/claude-managed-settings.json` contains a `__REPO_DIR__` token (used by `hooks` paths). setup.sh Phase 8a substitutes via `sed` before sudo-installing to `/etc/claude-code/managed-settings.json`. `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` deliberately live in `~/.profile` only (not managed-settings) so the user can point at a remote router without root.
- **Telemetry**: the systemd unit pins `LITELLM_MODE=PRODUCTION`, `LITELLM_LOG=ERROR`, and passes `--telemetry False`. Per LiteLLM docs, self-hosted instances do not phone home, but we set the flag defensively. `LITELLM_LOCAL_MODEL_COST_MAP` is deliberately left unset so LiteLLM refreshes `model_prices_and_context_window.json` from `BerriAI/litellm@main` on every start — without this, the UI's "Add Model" provider dropdown is capped at the catalog frozen into the installed wheel (e.g. no `gpt-5.3` until you `uv tool upgrade litellm`). Tradeoff: a small GitHub fetch at boot.
- **Hardening boundaries**: this repo intentionally does **not** ship `bunfig.toml`/`npmrc`/`uv.toml`/`pip.conf`. Supply-chain hardening lives outside this repo.

## Important Paths

- `~/.local/bin/litellm` — LiteLLM CLI (uv-installed)
- `~/.local/share/uv/tools/litellm/` — uv-managed virtualenv for LiteLLM and its deps
- `~/.config/litellm/{config.yaml, env}` — LiteLLM runtime state (env file holds master key, auto-discovered provider secrets, `DATABASE_URL`, `STORE_MODEL_IN_DB=True`, `LITELLM_DB_PASSWORD`)
- `/var/lib/postgresql/<version>/main/` — Postgres data dir (system-managed); database `litellm`, role `litellm`. Browse the LiteLLM UI at `http://127.0.0.1:4000/ui` with `admin` / the `LITELLM_MASTER_KEY` to add models without editing YAML
- `~/.local/share/claude-devtools/` — claude-devtools clone + build output (`dist-standalone/index.cjs`); `.dt-installed-tag` stamps the active release
- `~/.config/systemd/user/{litellm.service, claude-history.service, claude-devtools.service}` — systemd user units
- `/etc/claude-code/managed-settings.json` — system-level Claude Code policy (full + harden-only; skipped under `--router-only`; root-owned)
- `~/.claude/{settings.json, statusline.sh, projects/}` — user-level Claude Code state
- `~/.profile` — gateway URL, master key (as `ANTHROPIC_AUTH_TOKEN`), telemetry opt-outs (sourced by bash + zsh login shells)

## Troubleshooting

If LiteLLM fails to start, the service runs at `LITELLM_LOG=ERROR` which hides Prisma's "Run `prisma migrate resolve …`" recovery hints. To see them, edit `~/.config/systemd/user/litellm.service`, change `LITELLM_LOG=ERROR` to `LITELLM_LOG=INFO`, `systemctl --user daemon-reload && systemctl --user restart litellm`, and read `journalctl --user -u litellm -n 200`. Revert when done — INFO is very chatty in steady state.

**Statusbar shows `statusline skipped · restart to fix` and no trust prompt appears.** Caused by `IS_DEMO=1` leaking into the shell — Claude Code treats it as a "demo session" marker that silently suppresses the workspace-trust dialog without granting trust, so `statusLine` + hooks stay gated off and a restart doesn't help (anthropics/claude-code#37780, same flaw pattern as the fixed #10409). Phase 5a now strips it via `remove_profile_export "IS_DEMO"` (deletes the export from `~/.profile` and `unset`s it from the current shell). On a machine that ran an older setup, also check anywhere else it might be exported (`~/.bashrc`, `~/.zshrc`, container entrypoints, dotfiles), then relaunch `claude` and accept the trust prompt. As defense-in-depth Phase 8c only deploys `~/.claude/settings.json` on a fresh install — once Claude Code owns the file, re-running setup leaves it alone.

## Verification

```bash
bash -n linux/setup.sh && bash -n linux/common.sh                    # Syntax check
python3 -c "import yaml; yaml.safe_load(open('linux/configs/litellm-config.yaml'))"
jq . linux/configs/claude-managed-settings.json
systemctl --user status litellm claude-history                       # Service health
systemctl status postgresql                                          # DB up
curl -sf http://127.0.0.1:4000/health/liveliness                     # LiteLLM liveness
sudo -u postgres psql -d litellm -c '\dt' | grep LiteLLM_ProxyModelTable  # Prisma migrated
TOKEN=$(grep '^export ANTHROPIC_AUTH_TOKEN' ~/.profile | sed 's/.*="\(.*\)"/\1/')
curl -sf -H "Authorization: Bearer $TOKEN" http://127.0.0.1:4000/v1/models | jq .
```

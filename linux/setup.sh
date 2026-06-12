#!/bin/bash
#
# claude-litellm setup script
#
# Sets up LiteLLM gateway + (optionally) Claude Code on Debian/Kali Linux.
# Runs as the current $USER. Idempotent: install-if-missing, no upgrade-by-default.
#
# Usage:
#   ./linux/setup.sh                  # Full setup: LiteLLM + Claude Code + managed settings
#   ./linux/setup.sh --router-only    # LiteLLM gateway + Claude Code, no managed-settings hardening
#   ./linux/setup.sh --harden-only    # Only Claude Code + managed settings (no LiteLLM; remote router)
#   ./linux/setup.sh --install-obsidian  # Also install the ACP adapter + latest Obsidian (.deb); combinable with any mode
#   ./linux/setup.sh --docker         # Run LiteLLM via rootless Docker Compose (Postgres stays on the host); additive
#   ./linux/setup.sh --yes            # Non-interactive (skip prompts)
#
# --router-only and --harden-only are mutually exclusive. --install-obsidian and
# --docker are additive (combinable with any mode except --docker + --harden-only,
# which has no LiteLLM). Flags are NOT persisted — each invocation is fresh;
# rerunning without a flag falls through to full mode.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"

#############################################################################
# Parse Arguments
#############################################################################

ROUTER_ONLY=false
HARDEN_ONLY=false
INSTALL_OBSIDIAN=false
DOCKER_MODE=false
ORIGINAL_ARGS=("$@")

while [[ $# -gt 0 ]]; do
    case $1 in
        --router-only)
            ROUTER_ONLY=true
            shift
            ;;
        --harden-only)
            HARDEN_ONLY=true
            shift
            ;;
        --install-obsidian)
            INSTALL_OBSIDIAN=true
            shift
            ;;
        --docker)
            DOCKER_MODE=true
            shift
            ;;
        --yes)
            YES_MODE=true
            shift
            ;;
        -h|--help)
            sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [ "$ROUTER_ONLY" = "true" ] && [ "$HARDEN_ONLY" = "true" ]; then
    error "--router-only and --harden-only are mutually exclusive"
    exit 1
fi

# --docker dockerizes LiteLLM; --harden-only installs no LiteLLM at all.
if [ "$DOCKER_MODE" = "true" ] && [ "$HARDEN_ONLY" = "true" ]; then
    error "--docker and --harden-only are incompatible (--harden-only installs no LiteLLM)"
    exit 1
fi

# We expect to run as a regular user, not root.
if [ "$EUID" -eq 0 ]; then
    warn "Running as root is not recommended. Run it as your normal user; sudo is invoked where needed."
fi

if [ "$HARDEN_ONLY" = "true" ]; then
    log "claude-litellm setup starting (--harden-only mode)"
elif [ "$ROUTER_ONLY" = "true" ]; then
    log "claude-litellm setup starting (--router-only mode)"
else
    log "claude-litellm setup starting (full mode)"
fi
log "  REPO_DIR: $REPO_DIR"
log "  USER:     $USER"
log "  HOME:     $HOME"
if [ "$INSTALL_OBSIDIAN" = "true" ]; then
    log "  Obsidian + ACP install: enabled"
fi
if [ "$DOCKER_MODE" = "true" ]; then
    log "  LiteLLM runtime: rootless Docker Compose (Postgres on host)"
fi

#############################################################################
# Active Session Check
#############################################################################

# Check if Claude Code or ACP adapter is actively running as the current user.
# If so, skip the update to avoid disrupting:
#   - claude update (replaces binary mid-session)
#   - bun add -g for ACP (overwrites running binaries)
#   - litellm service restart (drops in-flight proxy connections)
if pgrep -u "$USER" -x "claude" &>/dev/null || \
   pgrep -u "$USER" -f "claude-agent-acp" &>/dev/null; then
    log "Claude Code or ACP adapter is running — skipping update to avoid session disruption"
    exit 0
fi

#############################################################################
# PHASE 0: Self-Update
#############################################################################

log "Checking for script updates..."
cd "$REPO_DIR"

if git rev-parse --git-dir > /dev/null 2>&1; then
    git fetch origin 2>/dev/null || true

    BEHIND=$(git rev-list HEAD..@{u} 2>/dev/null | wc -l)

    if [ "$BEHIND" -gt 0 ]; then
        log "Updates found! Pulling latest changes..."
        git pull --ff-only
        log "Re-executing updated script..."
        exec "$SCRIPT_DIR/setup.sh" "${ORIGINAL_ARGS[@]}"
        exit 0
    else
        log "Script is up to date"
    fi
else
    warn "Not running from a git repository. Self-update disabled."
fi

#############################################################################
# Constants (reused across phases)
#############################################################################

LITELLM_PORT=4000
# Unified Anthropic /v1/messages endpoint — translates to any provider in
# model_list. NOT the /anthropic pass-through (that one only proxies to api.anthropic.com).
ANTHROPIC_GATEWAY_URL="http://127.0.0.1:${LITELLM_PORT}"
# uv tool venv bin first: `prisma` CLI lives there (we install via --with prisma),
# and LiteLLM shells out to `prisma migrate deploy` on startup. Without this,
# migrations silently fail and UI-required tables like LiteLLM_UserTable never get created.
# Kept separate from USER_TOOL_PATH: the venv exposes generic names (httpx,
# openai, fastapi, nodeenv, mcp, …) that would shadow system tools for unrelated
# services.
LITELLM_PATH="${HOME}/.local/share/uv/tools/litellm/bin:${HOME}/.local/bin:${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin"
USER_TOOL_PATH="${HOME}/.local/bin:${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin"

#############################################################################
# PHASE 1: shell profile setup (Bash + zsh)
#############################################################################

log "=== Phase 1: shell profile setup ==="

# Ensure the ~/.bash_profile shim sources ~/.profile so bash login shells pick
# up our env vars. update_profile_export creates ~/.profile on demand.
ensure_managed_bash_profile

log "Shell profiles ready: ~/.profile, ~/.bash_profile shim"

#############################################################################
# PHASE 2: System packages (apt)
#############################################################################

log "=== Phase 2: System packages ==="

# Common packages always needed:
APT_PACKAGES="git curl jq ca-certificates unzip rsync"

# bubblewrap + socat + ripgrep in every mode. router-only ships the sandbox OFF by
# default (Phase 8c strips the block), but we still install the runtime so a user can
# opt in via /sandbox in the UI without re-running apt. The packages are tiny + benign.
# ripgrep is an undocumented /sandbox dep: the Mode/Overrides toggle tabs only render
# once every sandbox dependency resolves, and if Claude Code's bundled rg isn't found
# (it has regressed to a shell-shim before, anthropics/claude-code#31804, #31708) the
# user gets a deps-only screen with nothing to toggle. A real rg binary keeps it reachable.
APT_PACKAGES="$APT_PACKAGES bubblewrap socat ripgrep"

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
# shellcheck disable=SC2086
sudo apt-get install -y $APT_PACKAGES
log "System packages installed: $APT_PACKAGES"

# AppArmor profile for bwrap — configured in all modes so the sandbox works if a user
# opts into it via /sandbox (even under --router-only, which ships it off by default).
configure_bwrap_apparmor

# Enable systemd --user lingering early — needed by every mode's user services
# (litellm, claude-devtools) and, under --docker, by the rootless dockerd set up
# in Phase 2b (it runs as a systemd --user service). Enabling it before Phase 2b
# means the user manager + $XDG_RUNTIME_DIR are in place when the rootless
# setuptool runs (it uses `systemctl --user`), not just by the time Phase 7 needs it.
if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
    sudo loginctl enable-linger "$USER" 2>/dev/null || warn "Could not enable lingering for $USER"
    sleep 2
fi

#############################################################################
# PHASE 2b: Docker CE, rootless (only with --docker)
#############################################################################

# Installs Docker CE via the official apt repo and sets it up rootless (dockerd
# as a systemd --user service) so the dockerized LiteLLM in Phase 7 has a daemon
# to run against. Rootless keeps the repo's no-root-daemon / no-docker-group
# posture; see install_docker_rootless in common.sh. Only LiteLLM is
# containerized — Postgres stays on the host (Phase 6) and claude-devtools stays
# native (Phase 9).
if [ "$DOCKER_MODE" = "true" ]; then
    log "=== Phase 2b: Docker (rootless) ==="
    install_docker_rootless
fi

#############################################################################
# PHASE 3: bun + uv (install-if-missing-only)
#############################################################################

log "=== Phase 3: bun + uv ==="

if command -v bun &>/dev/null; then
    log "bun already installed ($(bun --version 2>/dev/null || echo '?')) — upgrading..."
    bun upgrade || warn "bun upgrade failed — keeping existing version"
else
    log "Installing bun..."
    download_and_run https://bun.sh/install bun
fi

if command -v uv &>/dev/null || [ -x "${HOME}/.local/bin/uv" ]; then
    # `uv self update` only works for the standalone (astral.sh) build. A uv from
    # pipx/pip/apt or a host-provided symlink rejects it — that uv is maintained
    # through its own channel, so treat the rejection as a clean skip, not a
    # failure. Resolve the real binary; uv may live outside ~/.local/bin.
    uv_bin="$(command -v uv 2>/dev/null || echo "${HOME}/.local/bin/uv")"
    if "$uv_bin" self update 2>/dev/null; then
        log "uv upgraded"
    else
        log "uv left as-is (self-update unavailable for this install method)"
    fi
else
    log "Installing uv..."
    download_and_run https://astral.sh/uv/install.sh uv sh
fi

# Symlink bun→node so #!/usr/bin/env node shebangs (ACP) resolve to bun.
# npx is a wrapper, not a symlink: bun's argv[0] sniffing only recognises
# "bunx"/"node", so a symlink invoked as "npx" runs `bun <arg>` and fails with
# `Script not found`. The wrapper calls `bun x` explicitly. Idempotent.
if [ -x "${HOME}/.bun/bin/bun" ]; then
    ln -sf "${HOME}/.bun/bin/bun" "${HOME}/.bun/bin/node"
    install -m 755 /dev/stdin "${HOME}/.bun/bin/npx" << NPX_EOF
#!/bin/sh
exec "${HOME}/.bun/bin/bun" x "\$@"
NPX_EOF
fi

# Ensure PATH entry for bun + uv in profile (idempotent)
ensure_path_in_profile 'export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"' "${HOME}/.profile"

# Source PATH for the rest of this script
export PATH="${HOME}/.bun/bin:${HOME}/.local/bin:${PATH}"

log "bun + uv ready"

#############################################################################
# PHASE 4: Tools (LiteLLM, Claude Code, optional ACP)
#############################################################################

log "=== Phase 4: Tools ==="

# 4a. LiteLLM via uv tool install (install-if-missing). uv was installed in
# Phase 3. Floor at >=1.84.0 (a floor, not a hard pin — fresh installs still get
# the latest, and a dependency cooldown picks the newest aged-in release). This
# floor sits above the compromised 1.82.7/1.82.8 PyPI releases (credential-
# stealing malware; see Anthropic's Claude Code LLM-gateway docs), so the old
# explicit `!=` excludes are no longer needed. It also guarantees the reasoning
# fixes this setup relies on for Azure GPT-5.4 thinking: the chat→Responses
# auto-route (1.83.0+) and the output_config.effort→reasoning_effort mapping
# (1.83.1+).
LITELLM_BIN="${HOME}/.local/bin/litellm"

# Skipped under --docker: the ghcr.io/berriai/litellm image already bundles
# LiteLLM + a generated Prisma client, so neither the uv tool install nor the
# `prisma generate` step below is needed.
if [ "$HARDEN_ONLY" != "true" ] && [ "$DOCKER_MODE" != "true" ]; then
    if [ -x "$LITELLM_BIN" ]; then
        # Upgrade-in-place (not skip): re-asserts the >=1.84.0 floor so an existing
        # install is lifted off a compromised 1.82.7/1.82.8 and picks up newer
        # aged-in releases. Idempotent no-op when already latest. The litellm.service
        # (re)start in the systemd step below loads the new version; the Prisma
        # client is force-regenerated against the (possibly new) schema via
        # LITELLM_UPGRADED.
        log "LiteLLM present at $LITELLM_BIN — upgrading (re-asserts >=1.84.0 floor)..."
        if uv tool install --upgrade --with prisma 'litellm[proxy,proxy-runtime]>=1.84.0'; then
            LITELLM_UPGRADED=1
        else
            warn "LiteLLM upgrade failed — keeping existing version"
        fi
    else
        log "Installing LiteLLM via uv tool install..."
        uv tool install --with prisma 'litellm[proxy,proxy-runtime]>=1.84.0'
        # To enable optional LiteLLM features, swap the line above for:
        #   uv tool install 'litellm[proxy,proxy-runtime,extra_proxy]>=1.84.0'
        # The extra_proxy extra adds: RedisVL semantic caching, Google Cloud KMS
        # + Azure Key Vault as secret backends, and Resend for email — plus
        # prisma, which makes --with prisma redundant.
    fi

    # Generate the Prisma client + fetch engine binaries. Upstream's Dockerfiles
    # do `prisma generate --schema=./schema.prisma` as a build step right after
    # pip install; `uv tool install` doesn't, so without this the proxy crashes
    # on first DB connect with "The Client hasn't been generated yet".
    # PRISMA_BINARY_CACHE_DIR must match the value in litellm.service or the
    # engine binaries get fetched twice (once here, once on first request).
    UV_LITELLM_VENV="${HOME}/.local/share/uv/tools/litellm"
    PRISMA_BINARY_CACHE_DIR="${HOME}/.cache/prisma-python/binaries"
    if [ -x "${UV_LITELLM_VENV}/bin/prisma" ]; then
        # Force regeneration after an upgrade (the new LiteLLM may ship a changed
        # schema.prisma); otherwise skip when a client is already present.
        if [ "${LITELLM_UPGRADED:-0}" != "1" ] && compgen -G "${UV_LITELLM_VENV}/lib/python*/site-packages/prisma/client.py" >/dev/null; then
            log "Prisma client already generated — skipping"
        else
            LITELLM_SCHEMA="$("${UV_LITELLM_VENV}/bin/python" -c 'import os, litellm.proxy as p; print(os.path.join(os.path.dirname(p.__file__), "schema.prisma"))' 2>/dev/null)"
            if [ -z "$LITELLM_SCHEMA" ] || [ ! -f "$LITELLM_SCHEMA" ]; then
                error "Could not locate litellm's schema.prisma; proxy will crash on first DB connect."
                exit 1
            fi
            log "Generating Prisma client (downloads ~50MB of engine binaries on first run)..."
            # Two non-obvious env tweaks for the nested generate process:
            #  - npm_config_min_release_age=0: prisma generate spawns
            #    `npm install prisma@<pinned>` via nodeenv. npm's
            #    `min-release-age` cooldown (npm 11.10.0+) is counted in DAYS,
            #    unlike pnpm/yarn (minutes) or bun (seconds). A user's ~/.npmrc
            #    may set it: the supply-chain hardening repo ships
            #    `min-release-age=7` (7 days), but an older revision shipped a
            #    stale `10080` (intended as pnpm-style minutes) which npm reads
            #    as ~27 years and which blocks the pinned 2024 prisma CLI.
            #    Override to 0 here for a deterministic install regardless of
            #    whatever cooldown the user has configured.
            #  - PATH prepend: prisma's Node CLI shells out to `prisma-client-py`
            #    (the Python generator binary), which lives in the uv tool
            #    venv. Without the prepend, the nested /bin/sh can't find it.
            PATH="${UV_LITELLM_VENV}/bin:$PATH" \
            PRISMA_BINARY_CACHE_DIR="$PRISMA_BINARY_CACHE_DIR" \
            npm_config_min_release_age=0 \
                "${UV_LITELLM_VENV}/bin/prisma" generate --schema="$LITELLM_SCHEMA"
        fi
    fi
fi

# 4b. Claude Code (install-if-missing via official installer; runs in all modes)
if command -v claude &>/dev/null || [ -x "${HOME}/.local/bin/claude" ]; then
    # Upgrade-in-place (not skip): `claude update` is a no-op when already latest
    # and still works under DISABLE_AUTOUPDATER=1 (that gates only the background
    # check, not the explicit command; DISABLE_UPDATES is not set). Resolve the
    # real binary; claude may live outside ~/.local/bin (e.g. a host-provided symlink).
    claude_bin="$(command -v claude 2>/dev/null || echo "${HOME}/.local/bin/claude")"
    log "Claude Code present — running 'claude update'..."
    "$claude_bin" update || warn "claude update failed — keeping existing version"
else
    log "Installing Claude Code..."
    # download_and_run (not `curl | bash`): a piped curl masks HTTP errors, so a
    # transient 403/network blip would silently leave `claude` uninstalled and a
    # downstream step would fail with a confusing "claude: not found". Verify after.
    download_and_run https://claude.ai/install.sh "Claude Code"
    command -v claude &>/dev/null || [ -x "${HOME}/.local/bin/claude" ] \
        || warn "Claude Code is NOT installed — 'claude' unavailable; dependent steps (e.g. MCP registration) will be skipped"
    # Re-establish bash_profile shim (the installer can drop its own)
    ensure_managed_bash_profile
fi

# 4c. ACP adapter (install-if-missing). Only installed with --install-obsidian:
# the ACP bridge exists to drive Claude Code from editors like Obsidian.
if [ "$INSTALL_OBSIDIAN" = "true" ]; then
    ACP_PACKAGE="@agentclientprotocol/claude-agent-acp"
    if [ -L "${HOME}/.bun/bin/claude-agent-acp" ] || [ -x "${HOME}/.bun/bin/claude-agent-acp" ]; then
        log "ACP adapter already installed — skipping"
    else
        log "Installing ACP adapter (${ACP_PACKAGE})..."
        bun add -g "$ACP_PACKAGE" || warn "ACP adapter install failed, continuing"
    fi
fi

# 4d. Obsidian desktop (install-if-missing). Resolve the latest amd64 .deb from
# the GitHub releases API and install via apt (apt resolves the .deb's deps).
# Only with --install-obsidian; failures are non-fatal.
if [ "$INSTALL_OBSIDIAN" = "true" ]; then
    # dpkg -s returns 0 even for removed-but-not-purged packages (config-files
    # state), so match the actual "install ok installed" status — otherwise an
    # `apt remove`d Obsidian would never get reinstalled here.
    if dpkg-query -W -f='${Status}' obsidian 2>/dev/null | grep -q 'install ok installed'; then
        log "Obsidian already installed — skipping (upgrade manually if needed)"
    else
        log "Resolving latest Obsidian amd64 .deb..."
        OBSIDIAN_DEB_URL="$(curl_secure -fsSL \
            https://api.github.com/repos/obsidianmd/obsidian-releases/releases/latest \
            | jq -r '.assets[] | select(.name | test("_amd64\\.deb$")) | .browser_download_url' \
            | head -n1)"
        if [ -z "$OBSIDIAN_DEB_URL" ] || [ "$OBSIDIAN_DEB_URL" = "null" ]; then
            warn "Could not resolve Obsidian amd64 .deb URL — skipping"
        # A bare `VAR=$(mktemp)` would abort the whole script under `set -e` if
        # mktemp fails; guard it so this block stays non-fatal as intended.
        elif ! OBSIDIAN_DEB="$(mktemp --suffix=.deb)"; then
            warn "Could not create temp file for Obsidian download — skipping"
        else
            log "Downloading Obsidian: $OBSIDIAN_DEB_URL"
            if curl_secure -fsSL -o "$OBSIDIAN_DEB" "$OBSIDIAN_DEB_URL"; then
                sudo apt-get install -y "$OBSIDIAN_DEB" || warn "Obsidian install failed, continuing"
            else
                warn "Obsidian download failed, continuing"
            fi
            rm -f "$OBSIDIAN_DEB"
        fi
    fi
fi

log "Tools phase complete"

#############################################################################
# PHASE 5: API keys + env vars
#############################################################################

log "=== Phase 5: env vars ==="

ENV_FILE="${REPO_DIR}/.env"
if [ -f "$ENV_FILE" ]; then
    # Source .env so we can pick out individual values below. Provider secrets
    # (AZURE_*/GEMINI_*/GOOGLE_*) are NOT written into ~/.profile — they live
    # only in the LiteLLM EnvironmentFile (mode 600).
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
else
    warn ".env not found at ${ENV_FILE}; continuing without it."
    warn "Provider vars from the current shell + ~/.profile will still be picked up."
    warn "To configure providers up front, copy .env.example to .env and fill it in."
fi

# 5a. Gateway URL + telemetry → ~/.profile (client-side; runs in every mode).
# These are the single source of truth for Claude Code's connection to LiteLLM —
# managed-settings.json no longer carries ANTHROPIC_BASE_URL/AUTH_TOKEN.
LITELLM_ENV_DIR="${HOME}/.config/litellm"
LITELLM_ENV_FILE="${LITELLM_ENV_DIR}/env"

# Preserve the auto-generated DB password across reruns. Selective grep
# rather than `source $LITELLM_ENV_FILE` because the latter would let stale
# provider secrets in the env file shadow fresh values from .env.
PERSISTED_DB_PASSWORD=""
if [ -f "$LITELLM_ENV_FILE" ]; then
    PERSISTED_DB_PASSWORD="$(grep '^LITELLM_DB_PASSWORD=' "$LITELLM_ENV_FILE" 2>/dev/null | cut -d= -f2-)"
fi

# Master key resolution. LiteLLM requires a master key starting with "sk-" for
# the unified /v1/messages endpoint. Order of precedence:
#   1. ANTHROPIC_AUTH_TOKEN from .env (user-managed)
#   2. existing value in ~/.profile (preserved across reruns)
#   3. auto-generated sk-<48 hex chars> on first run
if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
    ANTHROPIC_AUTH_TOKEN="$(read_profile_export ANTHROPIC_AUTH_TOKEN)"
fi
if [ -z "$ANTHROPIC_AUTH_TOKEN" ] || [ "$ANTHROPIC_AUTH_TOKEN" = "test" ]; then
    ANTHROPIC_AUTH_TOKEN="sk-$(openssl rand -hex 24)"
    log "Generated new LiteLLM master key (persisted to ~/.profile)"
fi

log "Writing gateway + telemetry env vars to ~/.profile..."

# Shell-wide telemetry opt-outs (not Claude Code specific)
update_profile_export "DO_NOT_TRACK"             "1"
update_profile_export "VSCODE_TELEMETRY_DISABLE" "1"
update_profile_export "VSCODE_CRASH_REPORTER_DISABLE" "1"
update_profile_export "DOTNET_CLI_TELEMETRY_OPTOUT"   "1"
update_profile_export "POWERSHELL_TELEMETRY_OPTOUT"   "1"
update_profile_export "HF_HUB_DISABLE_TELEMETRY"      "1"
update_profile_export "PYPI_DISABLE_TELEMETRY"        "1"
update_profile_export "UV_NO_TELEMETRY"               "1"
update_profile_export "DISABLE_GROWTHBOOK"            "1"
update_profile_export "SCARF_ANALYTICS"               "false"

# Subprocess env scrubbing: kept in ~/.profile (not managed-settings) so users
# can `unset CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` before `claude --dangerously-skip-permissions`
# when they need provider env vars to reach spawned subprocesses. Skipped under
# --router-only (a dev box where Bash/MCP/hooks should keep the full env, incl. the
# gateway token); removed there too so a box flipped from full mode is cleaned up.
if [ "$ROUTER_ONLY" = "true" ]; then
    remove_profile_export "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"
else
    update_profile_export "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB" "1"
fi

# Claude Code feature/privacy toggles. Also duplicated in managed-settings'
# env: block for full/harden modes; written here as well so they apply under
# --router-only (no managed-settings install) and reach subprocesses spawned
# by Claude Code. Grouped to mirror the managed-settings ordering.
update_profile_export "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC" "1"
update_profile_export "DISABLE_TELEMETRY"                        "1"
update_profile_export "DISABLE_ERROR_REPORTING"                  "1"

update_profile_export "DISABLE_FEEDBACK_COMMAND"                 "1"
update_profile_export "DISABLE_INSTALL_GITHUB_APP_COMMAND"       "1"

update_profile_export "ENABLE_CLAUDEAI_MCP_SERVERS"              "false"
update_profile_export "CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS"   "1"

# Non-hardening toggles
update_profile_export "CLAUDE_CODE_ATTRIBUTION_HEADER"           "0"

# Scrub IS_DEMO=1 from ~/.profile if a prior tool / demo container left it
# behind. Claude Code treats it as a "demo session" marker that silently
# suppresses the workspace-trust prompt without granting trust, breaking
# statusline + hooks (anthropics/claude-code #37780).
remove_profile_export "IS_DEMO"

# Default model selectors + gateway discovery. In ~/.profile (not managed-settings)
# so they apply in --router-only too. Values are the upstream provider-prefixed
# ids surfaced by litellm-config.yaml when Azure creds are supplied. When the
# user leaves Azure blank in .env, write empty values (unless a prior re-run /
# manual edit already set them) and emit a banner at end-of-script telling the
# user to add a model via /ui and fill these in. CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
# is always on so any `claude-*` model added later via /ui auto-appears in
# /model. See CLAUDE.md > "Model naming".
#
# The *_SUPPORTED_CAPABILITIES companions tell Claude Code which features the
# pinned model supports. Claude Code's built-in detection only matches
# claude-*/anthropic-* ids, so with upstream-prefixed ids like azure/gpt-5.4 it
# would otherwise leave extended thinking + effort DISABLED (and never send a
# thinking block). Values are tuned for Azure GPT-5.4: `xhigh_effort` is
# included for the gpt-5.4 tiers (GPT-5.4 accepts reasoning_effort=xhigh —
# Azure v1 API ref; surfacing it needs CC ≥2.1.111) and is safe at this repo's
# LiteLLM floor: ≥1.84.0 clamps effort levels the model map doesn't declare
# support for (max→xhigh→high, BerriAI/litellm#26111), so while the map's
# azure/ flags lag, xhigh silently runs as high — never an Azure 400.
# `max_effort` stays excluded: `max` is Anthropic-only, so it would *always*
# clamp — a permanently misleading picker entry. The haiku tier (gpt-5.4-mini)
# also omits `xhigh_effort` (its azure/ map flag is explicitly false, and
# xhigh on the fast tier defeats its purpose). `adaptive_thinking` routes
# effort via output_config.effort and avoids the manual-budget→"minimal" path
# that gpt-5.4 rejects. See CLAUDE.md > "Model naming".
NEEDS_MODEL_CONFIG=0
if [ -n "${AZURE_OPENAI_API_KEY:-}" ] && [ -n "${AZURE_RESOURCE_ENDPOINT:-}" ]; then
    update_profile_export "ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES"   "thinking,adaptive_thinking,interleaved_thinking,effort,xhigh_effort"
    update_profile_export "ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES" "thinking,adaptive_thinking,interleaved_thinking,effort,xhigh_effort"
    update_profile_export "ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES"  "thinking,adaptive_thinking,effort"
    update_profile_export "ANTHROPIC_DEFAULT_HAIKU_MODEL"  "azure/gpt-5.4-mini"
    update_profile_export "ANTHROPIC_DEFAULT_SONNET_MODEL" "azure/gpt-5.4"
    update_profile_export "ANTHROPIC_DEFAULT_OPUS_MODEL"   "azure/gpt-5.4"
else
    # Capability declarations track the model ids; clear them when no model is
    # pinned (preserving any manual value). Kept out of the NEEDS_MODEL_CONFIG
    # loop above — capabilities aren't themselves a reason to nag for a model id.
    for var in ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES \
               ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES \
               ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES; do
        if [ -z "$(read_profile_export "$var")" ]; then
            update_profile_export "$var" ""
        fi
    done
    for var in ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL; do
        existing="$(read_profile_export "$var")"
        if [ -z "$existing" ]; then
            update_profile_export "$var" ""
            NEEDS_MODEL_CONFIG=1
        fi
    done
fi
update_profile_export "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY" "1"

update_profile_export "NO_PROXY"             "127.0.0.1"
update_profile_export "API_TIMEOUT_MS"       "600000"

update_profile_export "LITELLM_API_KEY"      "$ANTHROPIC_AUTH_TOKEN"

update_profile_export "ANTHROPIC_BASE_URL"   "$ANTHROPIC_GATEWAY_URL"
update_profile_export "ANTHROPIC_AUTH_TOKEN" "$ANTHROPIC_AUTH_TOKEN"

# 5b. Provider secrets → in-memory env content. Auto-discovers every
# LiteLLM-relevant provider env var from current shell + ~/.profile + .env
# (sourced above). Skipped in harden-only since LiteLLM runs on another host.
if [ "$HARDEN_ONLY" != "true" ]; then
    LITELLM_ENV_CONTENT="LITELLM_MASTER_KEY=${ANTHROPIC_AUTH_TOKEN}"$'\n'
    LITELLM_ENV_CONTENT+="$(collect_litellm_provider_vars)"$'\n'
fi

#############################################################################
# PHASE 6: Postgres backing store + write LiteLLM env file
#############################################################################

# LiteLLM needs Postgres + STORE_MODEL_IN_DB=True to let users add models via
# /ui. Skipped in harden-only (no local LiteLLM). If DATABASE_URL was supplied
# in .env (now in current env), we trust the user's external Postgres and only
# skip the local apt install + role/db creation.
if [ "$HARDEN_ONLY" != "true" ]; then
    log "=== Phase 6: Postgres ==="

    if [ -n "${DATABASE_URL:-}" ] && [[ "${DATABASE_URL}" != postgresql://litellm:*@127.0.0.1:* ]]; then
        log "DATABASE_URL set externally — skipping local Postgres install"
        LITELLM_DB_URL="$DATABASE_URL"
    else
        if ! command -v psql &>/dev/null; then
            log "Installing postgresql via apt..."
            sudo apt-get install -y postgresql
        fi
        # Pick the cluster LiteLLM actually uses. Both the bootstrap below
        # (`sudo -u postgres psql`, via pg_wrapper) and the runtime DATABASE_URL
        # (127.0.0.1:5432) resolve to the cluster on port 5432 — postgresql-common's
        # own rule when several clusters exist ("the one listening on the default
        # port 5432"). Anchor on the port, not "the first cluster": pg_lsclusters
        # sorts by version, so after a major upgrade NR==1 can be a stale cluster
        # on 5433. The Port column is config-derived, so it's right even while down.
        pg_target=$(pg_lsclusters -h 2>/dev/null | awk '$3==5432 {print $1"-"$2; exit}' || true)

        # Make autostart survive reboot. Kali ships services preset-disabled, and
        # `postgresql.service` is a /bin/true umbrella whose link to the real
        # cluster instance is recreated each boot by a systemd generator that can
        # silently fail (systemd.generator early-boot limits) — leaving only the
        # dummy running and no socket. Enable the *instance* directly (the
        # postgresql@.service template ships [Install] WantedBy=multi-user.target)
        # so boot no longer depends on the generator firing.
        if [ -n "$pg_target" ]; then
            # Enable UNCONDITIONALLY (idempotent) + start with --now. Do NOT add an
            # `is-enabled` guard: that same generator marks the instance
            # "enabled-runtime" (a transient /run symlink) every boot and is-enabled
            # reports success for it, so any such guard skips the *persistent*
            # enable forever and the cluster stays dead after every reboot.
            sudo systemctl enable --now "postgresql@${pg_target}" || true
        else
            warn "No local Postgres cluster on port 5432 — falling back to 'systemctl start postgresql'"
            sudo systemctl start postgresql || true
        fi

        # Gate on the real socket via pg_isready, NOT `is-active postgresql`: the
        # umbrella reports active(exited) even when no cluster is online, so the old
        # check was a false positive that let the psql calls below run against a
        # dead socket (the "No such file or directory" failure on a fresh boot).
        for _ in {1..30}; do pg_isready -q && break; sleep 1; done
        pg_isready -q || { error "Postgres not accepting connections on port 5432 after 30s"; exit 1; }

        LITELLM_DB_PASSWORD="${PERSISTED_DB_PASSWORD:-$(openssl rand -hex 24)}"
        [ -z "$PERSISTED_DB_PASSWORD" ] && log "Generated new LITELLM_DB_PASSWORD"

        # Capture psql output to a variable so `set -e` catches psql failures
        # (a `psql | grep -q` pipe would mask them — grep's exit, not psql's).
        role_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='litellm'")
        if [ "$role_exists" = "1" ]; then
            # Only sync password when it actually changed — skip the SQL round-trip on no-op reruns.
            if [ "$LITELLM_DB_PASSWORD" != "$PERSISTED_DB_PASSWORD" ]; then
                sudo -u postgres psql -c "ALTER ROLE litellm WITH LOGIN PASSWORD '${LITELLM_DB_PASSWORD}'" >/dev/null
                log "Rotated Postgres role 'litellm' password"
            fi
        else
            sudo -u postgres psql -c "CREATE ROLE litellm WITH LOGIN PASSWORD '${LITELLM_DB_PASSWORD}'" >/dev/null
            log "Created Postgres role 'litellm'"
        fi
        db_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='litellm'")
        if [ "$db_exists" != "1" ]; then
            sudo -u postgres createdb -O litellm litellm
            log "Created Postgres database 'litellm'"
        fi

        # Same host DB in both modes — only the connection transport differs.
        # Native: TCP on loopback. --docker: the (rootless) LiteLLM container
        # connects over the host Postgres *Unix socket*, bind-mounted into the
        # container (no TCP listener, no network exposure — see CLAUDE.md "Docker
        # mode"). That needs a scoped `local` scram rule because Debian defaults
        # to peer auth. Re-running with/without --docker just rewrites the URL.
        if [ "$DOCKER_MODE" = "true" ]; then
            ensure_pg_socket_scram_rule
            LITELLM_DB_URL="postgresql://litellm:${LITELLM_DB_PASSWORD}@localhost/litellm?host=/run/postgresql"
        else
            LITELLM_DB_URL="postgresql://litellm:${LITELLM_DB_PASSWORD}@127.0.0.1:5432/litellm"
        fi
    fi

    LITELLM_ENV_CONTENT+="DATABASE_URL=${LITELLM_DB_URL}"$'\n'
    LITELLM_ENV_CONTENT+="STORE_MODEL_IN_DB=True"$'\n'
    [ -n "${LITELLM_DB_PASSWORD:-}" ] && LITELLM_ENV_CONTENT+="LITELLM_DB_PASSWORD=${LITELLM_DB_PASSWORD}"$'\n'

    # --docker only: ~/.config/litellm/env is parsed by BOTH systemd
    # EnvironmentFile (native unit) and docker-compose env_file (container). The
    # two parsers diverge on inline " #", surrounding quotes, and trailing
    # whitespace — a value with those reaches the provider intact natively but
    # garbled in the container (upstream 401/400). Real secrets never contain
    # these; warn so a stray one is caught instead of silently shipped.
    if [ "$DOCKER_MODE" = "true" ]; then
        while IFS= read -r _env_line; do
            case "$_env_line" in ''|'#'*) continue ;; esac
            if printf '%s' "${_env_line#*=}" | grep -qE '[[:space:]]#|[[:space:]]$|^["'\'']|["'\'']$'; then
                warn "env value for '${_env_line%%=*}' has characters docker-compose and systemd parse differently — verify it works under --docker (it may reach the provider garbled)"
            fi
        done <<< "$LITELLM_ENV_CONTENT"
    fi

    mkdir -p "$LITELLM_ENV_DIR"
    if printf '%s' "$LITELLM_ENV_CONTENT" | write_if_changed "$LITELLM_ENV_FILE" 600; then
        log "LiteLLM env file updated"
    else
        log "LiteLLM env file unchanged"
    fi
fi

#############################################################################
# PHASE 7: LiteLLM config + service
#############################################################################

# (systemd --user lingering is enabled earlier, before Phase 2b.)

if [ "$HARDEN_ONLY" != "true" ]; then
    log "=== Phase 7: LiteLLM ==="

    LITELLM_APP_DIR="${HOME}/.config/litellm"
    LITELLM_CONFIG_FILE="${LITELLM_APP_DIR}/config.yaml"

    deploy_config "$SCRIPT_DIR/configs/litellm-config.yaml" "$LITELLM_CONFIG_FILE"

    log "LiteLLM config deployed to $LITELLM_APP_DIR"

    # Runtime switch (native<->docker): stop the currently-installed litellm unit
    # BEFORE deploy_user_systemd_service daemon-reloads its definition, so it's
    # torn down via its OWN ExecStop. Critical for docker->native: otherwise the
    # redeployed native unit (which has no `docker compose down` ExecStop) can
    # leave the litellm container running under the rootless daemon, holding
    # 127.0.0.1:4000 and blocking the native proxy from binding. Only acts on an
    # actual variant change — a same-mode re-run is untouched here.
    INSTALLED_LITELLM_UNIT="${HOME}/.config/systemd/user/litellm.service"
    if [ -f "$INSTALLED_LITELLM_UNIT" ]; then
        installed_litellm_variant="native"
        grep -q 'docker compose' "$INSTALLED_LITELLM_UNIT" && installed_litellm_variant="docker"
        desired_litellm_variant="native"
        [ "$DOCKER_MODE" = "true" ] && desired_litellm_variant="docker"
        if [ "$installed_litellm_variant" != "$desired_litellm_variant" ]; then
            log "Switching LiteLLM runtime ${installed_litellm_variant} -> ${desired_litellm_variant}; stopping current unit first"
            stop_user_service_if_active litellm
            # systemd may read the unit inactive while the rootless daemon still
            # runs the container (restart: unless-stopped), so the ExecStop above
            # never fired and an orphan still holds 127.0.0.1:4000 — fatal for a
            # docker->native switch (the native proxy can't bind). Tear the compose
            # project down directly, independent of the unit state. Idempotent; if
            # the daemon/socket is down there's no running container to orphan.
            if [ "$installed_litellm_variant" = "docker" ] && [ -f "${LITELLM_APP_DIR}/docker-compose.yml" ]; then
                _litellm_sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"
                DOCKER_HOST="unix://${_litellm_sock}" \
                    docker compose -f "${LITELLM_APP_DIR}/docker-compose.yml" down --remove-orphans 2>/dev/null || true
            fi
        fi
    fi

    if [ "$DOCKER_MODE" = "true" ]; then
        # Dockerized LiteLLM: deploy the compose file next to config.yaml + env
        # (the unit's WorkingDirectory is __APP_DIR__, so `docker compose`
        # auto-discovers docker-compose.yml and the relative ./config.yaml + ./env
        # mounts). The systemd --user unit runs `docker compose up` against the
        # rootless daemon. Postgres + claude-devtools stay native.
        deploy_config "$SCRIPT_DIR/configs/litellm-docker-compose.yml" "${LITELLM_APP_DIR}/docker-compose.yml"
        log "LiteLLM docker-compose deployed to ${LITELLM_APP_DIR}/docker-compose.yml"

        deploy_user_systemd_service litellm "$SCRIPT_DIR/systemd/litellm-docker.service" \
            -e "s|__APP_DIR__|${LITELLM_APP_DIR}|g" \
            -e "s|__PATH__|${USER_TOOL_PATH}|g" || true

        # Pre-pull the image in the foreground (visible progress) so the unit
        # start below is fast and wait_for_litellm's 90s window isn't eaten by a
        # ~367MB first-run download — the unit's ExecStartPre would otherwise pull
        # silently while we poll. On re-runs with the image cached this is a quick
        # "up to date" check. Talks to the rootless daemon started in Phase 2b.
        litellm_docker_sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"
        log "Pulling LiteLLM image (first run downloads ~367MB; cached afterwards)..."
        DOCKER_HOST="unix://${litellm_docker_sock}" \
            docker compose -f "${LITELLM_APP_DIR}/docker-compose.yml" pull \
            || warn "docker compose pull failed — the unit will retry via ExecStartPre on start"
    else
        deploy_user_systemd_service litellm "$SCRIPT_DIR/systemd/litellm.service" \
            -e "s|__LITELLM_BIN__|${LITELLM_BIN}|g" \
            -e "s|__APP_DIR__|${LITELLM_APP_DIR}|g" \
            -e "s|__PORT__|${LITELLM_PORT}|g" \
            -e "s|__ENV_FILE__|${LITELLM_ENV_FILE}|g" \
            -e "s|__PATH__|${LITELLM_PATH}|g" || true
    fi

    systemctl --user enable litellm &>/dev/null || true

    if systemctl --user is-active litellm &>/dev/null; then
        systemctl --user restart litellm
        log "LiteLLM service restarted"
    else
        systemctl --user start litellm
        log "LiteLLM service started"
    fi

    wait_for_litellm "$LITELLM_PORT" || warn "LiteLLM may not be ready — Claude Code calls could fail until it starts"
fi

#############################################################################
# PHASE 8: Claude Code Managed Settings (only in full mode)
#############################################################################

log "=== Phase 8: Claude Code Settings ==="

# 8a: system-level hardening (managed-settings). Skipped in --router-only —
# that mode opts out of system-wide policy enforcement.
if [ "$ROUTER_ONLY" != "true" ]; then
    # 8a. Managed settings (system-level, root-owned). Token-substitute __REPO_DIR__ in hooks paths.
    sudo install -d -m 755 /etc/claude-code

    MANAGED_TMP=$(mktemp)
    sed \
        -e "s|__REPO_DIR__|${REPO_DIR}|g" \
        "$SCRIPT_DIR/configs/claude-managed-settings.json" > "$MANAGED_TMP"

    sudo install -m 644 -o root -g root "$MANAGED_TMP" /etc/claude-code/managed-settings.json
    rm -f "$MANAGED_TMP"
    log "Managed settings deployed to /etc/claude-code/managed-settings.json"
fi

# 8b. /tmp/claude (sandbox prerequisite; bashrc-ct.sh is gone, do it here). Runs in
# every mode — no sudo needed, and the sandbox runtime now ships in all modes (incl.
# --router-only, which can /sandbox on), so the prereq dir must exist everywhere.
mkdir -p /tmp/claude
chmod 755 /tmp/claude

# 8c + 8d: user-level state — runs in every mode (8a is root-only; 8b ran above).

# 8c. User settings. Deploy only on a fresh install — once Claude Code is
# running it owns this file (theme, plugins, accepted-bypass state); a
# re-run of setup must not clobber it.
NEEDS_SANDBOX_BLOCK=0
if [ ! -f "${HOME}/.claude/settings.json" ]; then
    if [ "$ROUTER_ONLY" = "true" ]; then
        # router-only ships the sandbox OFF, but KEEP the full block and just set
        # enabled:false (don't strip it). The floor (denyRead/denyWrite/network) stays
        # pre-configured, so flipping enabled:true later activates the hardened sandbox
        # with no re-config, and the statusline reflects whatever the user sets. bwrap
        # is installed in all modes (Phase 2).
        # Capture jq's output first: a bare `jq | write_if_changed` pipeline has no
        # pipefail (set -o pipefail isn't set), so a jq failure would be masked and
        # write_if_changed would write an empty settings.json and return 0. The
        # `VAR=$(jq …)` form aborts the script under `set -e` if jq fails.
        ROUTER_SETTINGS=$(jq '.sandbox.enabled = false' "$SCRIPT_DIR/configs/claude-settings.json")
        printf '%s\n' "$ROUTER_SETTINGS" \
            | write_if_changed "${HOME}/.claude/settings.json" 644 "${USER}:${USER}"
    else
        deploy_config "$SCRIPT_DIR/configs/claude-settings.json" "${HOME}/.claude/settings.json"
    fi
elif ! jq -e 'has("sandbox")' "${HOME}/.claude/settings.json" >/dev/null 2>&1; then
    # Existing CC-owned file with NO sandbox block: never auto-modify it, but without a
    # persisted block the statusline can't detect the sandbox (a /sandbox-picker toggle
    # is runtime-only — anthropics/claude-code#47624 — and undetectable). The fix-it
    # command (scripts/add-sandbox-block.sh — idempotent `//=` add-if-missing merge,
    # run by the user, keeps every other key) is surfaced in the end-of-script banner
    # via the NEEDS_MODEL_CONFIG pattern — printed inline here it would scroll off
    # behind Phases 9–11. The warn keeps non-tty runs (no banner) actionable.
    NEEDS_SANDBOX_BLOCK=1
    warn "~/.claude/settings.json has no sandbox block — run linux/scripts/add-sandbox-block.sh (details in the end-of-setup banner)."
fi

# 8d. Statusline script
install -m 755 "$SCRIPT_DIR/scripts/statusline.sh" "${HOME}/.claude/statusline.sh"

# 8e. nah Claude Code plugin — deterministic action-aware guard. Catches
# wrapper-evasion patterns the Bash(...) deny rules in managed-settings can't
# (sh -c, python -c, xargs rm, find -delete, git push -f short-form, …) by
# classifying commands into action types (filesystem_delete, lang_exec,
# git_history_rewrite, …) and resolving allow/ask/block with sensitive-path
# + content-scan context. Skipped under --router-only (no policy enforcement
# in that mode). PreToolUse hooks still fire under --dangerously-skip-permissions
# per Anthropic docs — the flag skips the deny/ask/allow rule chain and the
# user prompt, but hooks run *before* the prompt and remain active, so nah
# is the only active policy layer in that mode (and `permissions.deny[]` is
# idle). Marketplace ref uses @claude-marketplace branch (where upstream's
# marketplace.json lives) and is otherwise unpinned — same install-if-missing-
# then-latest convention as Claude Code (4b) and ACP (4c); user runs
# `claude plugin update nah --scope user` to upgrade.
if [ "$ROUTER_ONLY" != "true" ] && { command -v claude &>/dev/null || [ -x "${HOME}/.local/bin/claude" ]; }; then
    # Marketplace add: schema (verified via `claude plugin marketplace list
    # --json`) is bare array of { name, source, repo, installLocation } —
    # .source is the source TYPE ("github"), .repo holds "owner/repo". Match
    # on .repo for exact identity (avoids fork/mirror false positives).
    # Stdin redirected + timeout so a headless/CI invocation can't wedge the
    # script. Two independent hazards, two guards:
    #
    #   1. TTY probing (the real wedger). `claude` is a Node TUI: when its
    #      stdout is an interactive terminal it emits terminal-capability
    #      queries (OSC 11 background-colour, DA1 device-attributes) AFTER
    #      doing its work and blocks waiting for the replies — which arrive on
    #      stdin, but stdin is </dev/null here, so they never come and it hangs
    #      forever (it has already printed "Successfully installed", so the
    #      on-disk action is done). The read-only calls dodge this for free by
    #      piping stdout into tr|sed|jq — a pipe is not a tty, so isTTY is
    #      false and claude stays non-interactive. The mutating calls must do
    #      the same: wrap in `$(... 2>&1)` so stdout/stderr are pipes, not the
    #      terminal. Output is captured and surfaced only on failure.
    #   2. timeout signal escalation (belt-and-suspenders). Plain `timeout N`
    #      sends only SIGTERM then waits for the child; a Node process that
    #      traps it or keeps a handle open is never killed and timeout waits
    #      forever. `-k <grace>` escalates to uncatchable SIGKILL. The
    #      add/install calls clone over the network under claude's own 120s
    #      internal git timeout, so their outer bound is 180s (above 120s) to
    #      avoid cutting a slow-but-working first clone; -k 15 force-kills 15s
    #      later. State is committed before any lingering, so a force-kill
    #      never corrupts it (re-runs find it "already added"/installed).
    nah_marketplace_ok=0
    # `claude plugin marketplace list --json` emits CRLF line endings and a
    # trailing ANSI escape (\e[?25h) past the closing `]` — strip both before
    # jq sees the input. Same workaround applied to `claude plugin list --json`
    # below; see comment there for the empirical evidence.
    if timeout -k 15 60 claude plugin marketplace list --json </dev/null 2>/dev/null \
        | tr -d '\r' \
        | sed -n '/^\[/,/^\]/p' \
        | jq -e '.[]? | select(.repo == "manuelschipper/nah")' >/dev/null 2>&1; then
        log "nah marketplace already added — skipping"
        nah_marketplace_ok=1
    else
        log "Adding nah plugin marketplace..."
        # @claude-marketplace is the git ref where marketplace.json lives in
        # the upstream repo — the default branch does not contain it, so the
        # bare `manuelschipper/nah` form fails with "marketplace.json not found".
        # The .repo field in `claude plugin marketplace list --json` drops the
        # ref suffix, so the idempotency selector above still matches.
        # $(... 2>&1) keeps stdout/stderr off the tty (hazard 1 above) so the
        # add doesn't block on terminal-capability probes; if-condition form is
        # set -e-safe (substitution failure doesn't abort the script).
        if nah_add_out=$(timeout -k 15 180 claude plugin marketplace add manuelschipper/nah@claude-marketplace </dev/null 2>&1); then
            nah_marketplace_ok=1
        else
            warn "Failed to add nah marketplace — try 'claude update' (the 'plugin' subcommand may be missing in older Claude Code). Output: ${nah_add_out}"
        fi
    fi

    # Only attempt install if the marketplace is registered — otherwise the
    # install call is guaranteed to fail with a less informative error.
    #
    # Plugin schema (verified via `claude plugin list --json` on a real install):
    # bare array of { id: "<plugin>@<marketplace>", scope, enabled, version,
    # installedAt, ... }. No .name field. `claude plugin install` enables the
    # plugin by default, so the `absent` branch below installs *and* enables
    # (the explicit enable is a tolerant no-op if install already did it, and a
    # safety net on the odd build that leaves it disabled). Consequently an
    # `enabled: false` at detection time means the user *deliberately* disabled
    # it after we installed it (`claude plugin disable`) — Phase 8e respects
    # that and leaves it off (it does NOT re-enable). We distinguish three states.
    if [ "$nah_marketplace_ok" = "1" ]; then
        # Note: `// "absent"` won't work as a fallback because jq's // operator
        # treats both null AND false as missing — so an installed-but-disabled
        # plugin (enabled: false) would silently look "absent". Use if/else.
        #
        # Defensive: stage the raw output so we can distinguish "empty output"
        # (claude crashed / subcommand missing) from "parse error" (claude
        # emitted JSON + trailing noise) from "valid output, plugin absent".
        # An ambiguous state should NOT trigger reinstall (would spam install
        # attempts on every re-run); warn and skip until the next run.
        #
        # `claude plugin list --json` (verified empirically) writes JSON with
        # CRLF line endings AND appends a trailing ANSI escape `\e[?25h`
        # (show-cursor) past the closing `]`. Strip CR with `tr -d '\r'` and
        # extract just the bracketed array with `sed -n '/^\[/,/^\]/p'` so jq
        # gets clean input. The sed range tolerates a single-line `[]` (both
        # anchors match the same line, printed once).
        plugin_list=$(timeout -k 15 60 claude plugin list --json </dev/null 2>/dev/null \
            | tr -d '\r' \
            | sed -n '/^\[/,/^\]/p' \
            || true)
        if [ -z "$plugin_list" ]; then
            nah_state="unknown"
        else
            nah_state=$(printf '%s' "$plugin_list" \
                | jq -r '[.[]? | select(.id == "nah@nah" and .scope == "user")] | if length == 0 then "absent" else .[0].enabled end' 2>/dev/null \
                || echo "parse-error")
        fi
        case "$nah_state" in
            true)
                log "nah plugin already installed and enabled — skipping"
                ;;
            false)
                # User deliberately disabled it (install enables by default, and
                # the absent branch re-asserts enable, so a disabled state can only
                # come from `claude plugin disable`). Respect that — do NOT re-enable.
                log "nah plugin installed but disabled — leaving disabled (user opted out; run 'claude plugin enable nah@nah --scope user' to re-enable)"
                ;;
            absent)
                log "Installing nah Claude Code plugin..."
                if nah_install_out=$(timeout -k 15 180 claude plugin install nah@nah --scope user </dev/null 2>&1); then
                    log "nah plugin installed"
                    # install enables by default; assert it on first install so a
                    # fresh box ends up enabled regardless of build behaviour. A
                    # benign "already enabled" error here is expected and ignored.
                    # We do this ONLY on first install — never in the `false`
                    # branch, where a disabled plugin is the user's choice.
                    timeout -k 15 60 claude plugin enable nah@nah --scope user </dev/null >/dev/null 2>&1 || true
                else
                    warn "Failed to install nah plugin — try 'claude plugin marketplace list' to confirm marketplace registration. Output: ${nah_install_out}"
                fi
                ;;
            *)
                warn "Could not determine nah plugin state ('$nah_state') — skipping mutation; re-run setup.sh to retry"
                ;;
        esac
    fi
fi

log "Claude Code settings deployed"

#############################################################################
# PHASE 9: Claude DevTools
#############################################################################

CLAUDE_DEVTOOLS_DEPLOYED=0
CLAUDE_DEVTOOLS_RAM_OK=0
if [ "$HARDEN_ONLY" != "true" ]; then
    # RAM gate: vite's renderer build (mermaid + react + dnd-kit, 4333 modules)
    # peaks at ~3-4 GB RSS and gets OOM-killed on smaller boxes. Floor is 3.5 GB
    # MemTotal — a nominally-4-GB VM typically reports ~3.8 GB after kernel
    # reservations, and the env hedges below (BUN_OPTIONS=--smol, GOMEMLIMIT,
    # MALLOC_ARENA_MAX) plus a bit of swap make the build succeed in practice.
    devtools_ram_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    if [ "${devtools_ram_kb:-0}" -ge 3670016 ]; then
        CLAUDE_DEVTOOLS_RAM_OK=1
    else
        devtools_ram_gb=$(awk -v kb="$devtools_ram_kb" 'BEGIN {printf "%.1f", kb/1024/1024}')
        warn "Skipping Phase 9 (claude-devtools) — needs >=3.5 GB RAM (found ${devtools_ram_gb} GB)"
        warn "  vite's renderer build OOMs on smaller boxes; bump VM RAM or add swap to enable"
    fi
fi

if [ "$CLAUDE_DEVTOOLS_RAM_OK" = "1" ]; then
    log "=== Phase 9: Claude DevTools ==="

    CLAUDE_DEVTOOLS_PORT=12002
    CLAUDE_DEVTOOLS_DIR="${HOME}/.local/share/claude-devtools"
    CLAUDE_DEVTOOLS_REPO="https://github.com/matt1398/claude-devtools.git"
    CLAUDE_DEVTOOLS_BUN="${HOME}/.bun/bin/bun"
    CLAUDE_DEVTOOLS_PNPM="${HOME}/.bun/bin/pnpm"
    CLAUDE_DEVTOOLS_STAMP="${CLAUDE_DEVTOOLS_DIR}/.dt-installed-tag"
    CLAUDE_DEVTOOLS_BUILD="${CLAUDE_DEVTOOLS_DIR}/dist-standalone/index.cjs"

    # pnpm is the build-time package manager: claude-devtools declares it via
    # package.json's `packageManager` field, ships a pnpm-lock.yaml, and is a
    # pnpm workspace. Bun mis-handles all three. Bun stays as the *runtime*
    # (systemd service still does `bun run dist-standalone/index.cjs`).
    if [ -L "$CLAUDE_DEVTOOLS_PNPM" ] || [ -x "$CLAUDE_DEVTOOLS_PNPM" ]; then
        log "pnpm already installed — skipping"
    else
        log "Installing pnpm (build-time dep of claude-devtools)..."
        bun add -g pnpm@10 || warn "Failed to install pnpm — claude-devtools build will fail"
    fi

    if [ ! -d "${CLAUDE_DEVTOOLS_DIR}/.git" ]; then
        log "Cloning claude-devtools..."
        mkdir -p "$CLAUDE_DEVTOOLS_DIR"
        git clone --depth 1 --no-tags "$CLAUDE_DEVTOOLS_REPO" "$CLAUDE_DEVTOOLS_DIR" \
            || warn "Failed to clone claude-devtools — skipping phase"
    fi

    CLAUDE_DEVTOOLS_LATEST_TAG=""
    if [ -d "${CLAUDE_DEVTOOLS_DIR}/.git" ]; then
        # ls-remote queries the server directly — works on shallow/--no-tags clones.
        CLAUDE_DEVTOOLS_LATEST_TAG=$(cd "$CLAUDE_DEVTOOLS_DIR" && git ls-remote --refs --tags --sort=-v:refname origin 'v*' 2>/dev/null | head -1 | awk -F'refs/tags/' '{print $2}' || true)
        if [ -z "$CLAUDE_DEVTOOLS_LATEST_TAG" ]; then
            CLAUDE_DEVTOOLS_LATEST_TAG=$(cd "$CLAUDE_DEVTOOLS_DIR" && git ls-remote --refs --tags --sort=-v:refname origin 2>/dev/null | head -1 | awk -F'refs/tags/' '{print $2}' || true)
        fi

        # Defense in depth: a hostile upstream could push a tag with shell
        # metacharacters. Restrict to characters git allows in tag names that
        # are also shell-safe.
        if [ -n "$CLAUDE_DEVTOOLS_LATEST_TAG" ] && ! [[ "$CLAUDE_DEVTOOLS_LATEST_TAG" =~ ^[A-Za-z0-9._/-]+$ ]]; then
            warn "Refusing claude-devtools tag with unsafe characters: ${CLAUDE_DEVTOOLS_LATEST_TAG}"
            CLAUDE_DEVTOOLS_LATEST_TAG=""
        fi

        CLAUDE_DEVTOOLS_INSTALLED_TAG=""
        [ -f "$CLAUDE_DEVTOOLS_STAMP" ] && CLAUDE_DEVTOOLS_INSTALLED_TAG=$(cat "$CLAUDE_DEVTOOLS_STAMP" 2>/dev/null || true)

        if [ -z "$CLAUDE_DEVTOOLS_LATEST_TAG" ]; then
            warn "Could not resolve latest claude-devtools tag — keeping existing build"
        elif [ "$CLAUDE_DEVTOOLS_INSTALLED_TAG" = "$CLAUDE_DEVTOOLS_LATEST_TAG" ] && [ -f "$CLAUDE_DEVTOOLS_BUILD" ]; then
            log "claude-devtools is up to date at $CLAUDE_DEVTOOLS_INSTALLED_TAG"
        else
            log "claude-devtools: ${CLAUDE_DEVTOOLS_INSTALLED_TAG:-<none>} -> ${CLAUDE_DEVTOOLS_LATEST_TAG}"
            if ! (cd "$CLAUDE_DEVTOOLS_DIR" && git fetch --depth 1 --no-tags origin tag "$CLAUDE_DEVTOOLS_LATEST_TAG" && git -c advice.detachedHead=false checkout --force "refs/tags/$CLAUDE_DEVTOOLS_LATEST_TAG" && git clean -fdx -e .dt-installed-tag); then
                warn "Failed to check out claude-devtools tag $CLAUDE_DEVTOOLS_LATEST_TAG"
            else
                log "Building claude-devtools (this may take 2-3 min)..."
                # Memory mitigations stacked across runtime layers (each saves a few
                # hundred MB; together they buy headroom for borderline boxes — the
                # hard skip below 3.5 GB is enforced above):
                #   MALLOC_ARENA_MAX    glibc: cap per-thread malloc arenas
                #   GOMEMLIMIT          esbuild's Go runtime: soft GC ceiling
                #   BUN_OPTIONS=--smol  bun: docs-recommended low-memory mode (node->bun shim runs the build)
                #   NODE_OPTIONS        V8 hedge if a future run uses real Node
                if ! (
                    cd "$CLAUDE_DEVTOOLS_DIR" &&
                    export ELECTRON_SKIP_BINARY_DOWNLOAD=1 npm_config_electron_skip_binary_download=true \
                        MALLOC_ARENA_MAX=2 \
                        GOMEMLIMIT=2048MiB \
                        BUN_OPTIONS="--smol" \
                        NODE_OPTIONS="--max-old-space-size=2048 --optimize-for-size" &&
                    "$CLAUDE_DEVTOOLS_PNPM" install --frozen-lockfile &&
                    "$CLAUDE_DEVTOOLS_PNPM" run standalone:build
                ); then
                    warn "claude-devtools build failed — service will not be (re)deployed"
                elif [ ! -f "$CLAUDE_DEVTOOLS_BUILD" ]; then
                    warn "claude-devtools build finished but $CLAUDE_DEVTOOLS_BUILD missing"
                else
                    echo "$CLAUDE_DEVTOOLS_LATEST_TAG" | write_if_changed "$CLAUDE_DEVTOOLS_STAMP"
                    log "claude-devtools built successfully at $CLAUDE_DEVTOOLS_LATEST_TAG"
                fi
            fi
        fi
    fi

    if [ -f "$CLAUDE_DEVTOOLS_BUILD" ]; then
        deploy_user_systemd_service claude-devtools "$SCRIPT_DIR/systemd/claude-devtools.service" \
            -e "s|__CLAUDE_DEVTOOLS_DIR__|${CLAUDE_DEVTOOLS_DIR}|g" \
            -e "s|__CLAUDE_DEVTOOLS_PORT__|${CLAUDE_DEVTOOLS_PORT}|g" \
            -e "s|__BUN_BIN__|${CLAUDE_DEVTOOLS_BUN}|g" \
            -e "s|__HOME__|${HOME}|g" \
            -e "s|__PATH__|${USER_TOOL_PATH}|g" || true

        systemctl --user enable claude-devtools &>/dev/null || true
        if systemctl --user restart claude-devtools; then
            CLAUDE_DEVTOOLS_DEPLOYED=1
        else
            warn "Failed to start claude-devtools"
        fi
    else
        warn "claude-devtools build output missing — service deployment skipped"
    fi
fi

#############################################################################
# PHASE 10: remove legacy claude-run + claude-history service
#############################################################################

# Cleanup-only phase: claude-run + its claude-history.service log viewer used
# to live on port 12001. They were removed; this phase scrubs both from any
# machine that ran an older setup. Runs in all modes (a previous --router-only
# / full install on this host may have deployed them).
LEGACY_HISTORY_SERVICE="${HOME}/.config/systemd/user/claude-history.service"
LEGACY_CLAUDE_RUN_BIN="${HOME}/.bun/bin/claude-run"
if [ -f "$LEGACY_HISTORY_SERVICE" ] || [ -L "$LEGACY_CLAUDE_RUN_BIN" ] || [ -x "$LEGACY_CLAUDE_RUN_BIN" ]; then
    log "=== Phase 10: removing legacy claude-run + claude-history service ==="
    if [ -f "$LEGACY_HISTORY_SERVICE" ]; then
        systemctl --user disable --now claude-history &>/dev/null || true
        rm -f "$LEGACY_HISTORY_SERVICE"
        systemctl --user daemon-reload &>/dev/null || true
        log "Removed claude-history.service"
    fi
    if [ -L "$LEGACY_CLAUDE_RUN_BIN" ] || [ -x "$LEGACY_CLAUDE_RUN_BIN" ]; then
        log "Uninstalling claude-run (bun remove -g)..."
        bun remove -g claude-run &>/dev/null || true
        # Belt-and-braces: if bun left the symlink behind (stale lockfile), drop it.
        [ -L "$LEGACY_CLAUDE_RUN_BIN" ] && rm -f "$LEGACY_CLAUDE_RUN_BIN"
    fi
fi

#############################################################################
# PHASE 11: APT cleanup
#############################################################################

log "=== Phase 11: Cleanup ==="

sudo apt-get autoremove -y

#############################################################################
# Done
#############################################################################

# Final safety net for bash_profile shim (curl-pipe installers can clobber it)
ensure_managed_bash_profile

log "claude-litellm setup complete!"
if [ "$HARDEN_ONLY" != "true" ]; then
    log "  LiteLLM UI:  http://127.0.0.1:${LITELLM_PORT}/ui/"
    if [ "$CLAUDE_DEVTOOLS_DEPLOYED" = "1" ]; then
        log "  DevTools UI: http://127.0.0.1:${CLAUDE_DEVTOOLS_PORT}"
    fi
fi
log ""
log "Log out and back in (or run 'source ~/.profile') to load the env vars — a plain new terminal won't read ~/.profile."
if [ "$HARDEN_ONLY" = "true" ]; then
    log "ANTHROPIC_BASE_URL in ~/.profile is currently: ${ANTHROPIC_GATEWAY_URL}"
    log "Edit ~/.profile (or set ANTHROPIC_GATEWAY_URL in .env and re-run) to point at your remote LiteLLM."
fi
log "Then run 'claude' to start Claude Code via the LiteLLM gateway."

# Skip on systemd / piped runs
if [ "$HARDEN_ONLY" != "true" ] && [ -t 1 ]; then
    rule="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo -e "${YELLOW}${rule}${NC}"
    echo -e "${YELLOW}  LiteLLM UI:  ${NC}http://127.0.0.1:${LITELLM_PORT}/ui/"
    echo -e "${YELLOW}  Username:    ${NC}admin"
    echo -e "${YELLOW}  Password:    ${GREEN}${ANTHROPIC_AUTH_TOKEN}${NC}"
    echo ""
    echo -e "${YELLOW}  To retrieve later: ${NC}grep '^LITELLM_MASTER_KEY=' ~/.config/litellm/env"
    echo -e "${YELLOW}${rule}${NC}"
    echo ""
fi

if [ "${NEEDS_MODEL_CONFIG:-0}" = "1" ] && [ -t 1 ]; then
    rule="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${YELLOW}${rule}${NC}"
    echo -e "${YELLOW}  No Azure credentials in .env — setup completed, but Claude Code"
    echo -e "  has NO default model configured yet.${NC}"
    echo ""
    echo -e "${YELLOW}  Next steps:${NC}"
    echo -e "    1. Open ${GREEN}http://127.0.0.1:${LITELLM_PORT}/ui${NC} and add at least one model."
    echo -e "    2. Edit ${GREEN}~/.profile${NC} and set the three default-model vars to the"
    echo -e "       Public Model Name you added (same name works for all three):"
    echo -e "         ${GREEN}export ANTHROPIC_DEFAULT_HAIKU_MODEL=\"<name>\"${NC}"
    echo -e "         ${GREEN}export ANTHROPIC_DEFAULT_SONNET_MODEL=\"<name>\"${NC}"
    echo -e "         ${GREEN}export ANTHROPIC_DEFAULT_OPUS_MODEL=\"<name>\"${NC}"
    echo -e "    3. If that name is not \`claude-*\`/\`anthropic-*\`, also declare its"
    echo -e "       capabilities or Claude Code leaves thinking + effort OFF:"
    echo -e "         ${GREEN}export ANTHROPIC_DEFAULT_{HAIKU,SONNET,OPUS}_MODEL_SUPPORTED_CAPABILITIES=\"thinking,adaptive_thinking,interleaved_thinking,effort\"${NC}"
    echo -e "    4. ${GREEN}source ~/.profile${NC} (or log out and back in) before \`claude\`."
    echo -e "${YELLOW}${rule}${NC}"
    echo ""
fi

if [ "${NEEDS_SANDBOX_BLOCK:-0}" = "1" ] && [ -t 1 ]; then
    rule="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${YELLOW}${rule}${NC}"
    echo -e "${YELLOW}  ~/.claude/settings.json has no sandbox block — the statusline can't"
    echo -e "  detect the sandbox. Add it (keeps your other keys), then restart"
    echo -e "  Claude Code:${NC}"
    echo ""
    if [ "$ROUTER_ONLY" = "true" ]; then
        echo -e "    ${GREEN}${SCRIPT_DIR}/scripts/add-sandbox-block.sh --disabled${NC}"
        echo ""
        echo -e "${YELLOW}  (router-only seeds it disabled — set sandbox.enabled:true to turn it on)${NC}"
    else
        echo -e "    ${GREEN}${SCRIPT_DIR}/scripts/add-sandbox-block.sh${NC}"
    fi
    echo -e "${YELLOW}${rule}${NC}"
    echo ""
fi

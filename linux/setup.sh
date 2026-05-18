#!/bin/bash
#
# claude-litellm setup script
#
# Sets up LiteLLM gateway + (optionally) Claude Code on Debian/Kali Linux.
# Runs as the current $USER. Idempotent: install-if-missing, no upgrade-by-default.
#
# Usage:
#   ./linux/setup.sh                  # Full setup: LiteLLM + Claude Code + managed settings
#   ./linux/setup.sh --router-only    # LiteLLM gateway + Claude Code, no managed-settings hardening or ACP
#   ./linux/setup.sh --harden-only    # Only Claude Code + managed settings (no LiteLLM; remote router)
#   ./linux/setup.sh --yes            # Non-interactive (skip prompts)
#
# --router-only and --harden-only are mutually exclusive. Flags are NOT persisted —
# each invocation is fresh; rerunning without a flag falls through to full mode.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"

#############################################################################
# Parse Arguments
#############################################################################

ROUTER_ONLY=false
HARDEN_ONLY=false
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

# We expect to run as a regular user, not root.
if [ "$EUID" -eq 0 ]; then
    error "Do not run this script as root. Run it as your normal user; sudo is invoked where needed."
    exit 1
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
        exec "$0" "${ORIGINAL_ARGS[@]}"
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
CLAUDE_RUN_PORT=12001
# Unified Anthropic /v1/messages endpoint — translates to any provider in
# model_list. NOT the /anthropic pass-through (that one only proxies to api.anthropic.com).
ANTHROPIC_GATEWAY_URL="http://127.0.0.1:${LITELLM_PORT}"
# uv tool venv bin first: `prisma` CLI lives there (we install via --with prisma),
# and LiteLLM shells out to `prisma migrate deploy` on startup. Without this,
# migrations silently fail and UI-required tables like LiteLLM_UserTable never get created.
# Kept separate from CLAUDE_RUN_PATH: the venv exposes generic names (httpx,
# openai, fastapi, nodeenv, mcp, …) that would shadow system tools for unrelated
# services.
LITELLM_PATH="${HOME}/.local/share/uv/tools/litellm/bin:${HOME}/.local/bin:${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin"
CLAUDE_RUN_PATH="${HOME}/.local/bin:${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin"

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

# bubblewrap + socat only for full mode (Claude Code sandbox uses bwrap):
if [ "$ROUTER_ONLY" != "true" ]; then
    APT_PACKAGES="$APT_PACKAGES bubblewrap socat"
fi

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
# shellcheck disable=SC2086
sudo apt-get install -y $APT_PACKAGES
log "System packages installed: $APT_PACKAGES"

# AppArmor profile for bwrap, only relevant in full mode
if [ "$ROUTER_ONLY" != "true" ]; then
    configure_bwrap_apparmor
fi

#############################################################################
# PHASE 3: bun + uv (install-if-missing-only)
#############################################################################

log "=== Phase 3: bun + uv ==="

if command -v bun &>/dev/null; then
    log "bun already installed ($(bun --version 2>/dev/null || echo '?')) — skipping install"
else
    log "Installing bun..."
    curl_secure -fsSL https://bun.sh/install | bash
fi

if command -v uv &>/dev/null || [ -x "${HOME}/.local/bin/uv" ]; then
    log "uv already installed — skipping install"
else
    log "Installing uv..."
    curl_secure -fsSL https://astral.sh/uv/install.sh | sh
fi

# Symlink bun→node and bunx→npx so #!/usr/bin/env node shebangs (claude-run, ACP)
# resolve to bun. Idempotent.
if [ -x "${HOME}/.bun/bin/bun" ]; then
    ln -sf "${HOME}/.bun/bin/bun"  "${HOME}/.bun/bin/node"
    ln -sf "${HOME}/.bun/bin/bunx" "${HOME}/.bun/bin/npx"
fi

# Ensure PATH entry for bun + uv in profile (idempotent)
ensure_path_in_profile 'export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"' "${HOME}/.profile"

# Source PATH for the rest of this script
export PATH="${HOME}/.bun/bin:${HOME}/.local/bin:${PATH}"

log "bun + uv ready"

#############################################################################
# PHASE 4: Tools (LiteLLM, claude-run, optional Claude Code + ACP)
#############################################################################

log "=== Phase 4: Tools ==="

# 4a. LiteLLM via uv tool install (install-if-missing). uv was installed in
# Phase 3. Pin away from PyPI 1.82.7 and 1.82.8 — those releases were
# compromised with credential-stealing malware (see Anthropic's Claude Code
# LLM-gateway docs).
LITELLM_BIN="${HOME}/.local/bin/litellm"

if [ "$HARDEN_ONLY" != "true" ]; then
    if [ -x "$LITELLM_BIN" ]; then
        log "LiteLLM already installed at $LITELLM_BIN — skipping"
    else
        log "Installing LiteLLM via uv tool install..."
        uv tool install --with prisma 'litellm[proxy,proxy-runtime]>=1.83.0,!=1.82.7,!=1.82.8'
        # To enable optional LiteLLM features, swap the line above for:
        #   uv tool install 'litellm[proxy,proxy-runtime,extra_proxy]>=1.83.0,!=1.82.7,!=1.82.8'
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
        if compgen -G "${UV_LITELLM_VENV}/lib/python*/site-packages/prisma/client.py" >/dev/null; then
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
            #    `npm install prisma@<pinned>` via nodeenv. If the user has
            #    `min-release-age` set in ~/.npmrc, npm 11.x misreads the unit
            #    (treats the minutes-spec value as days) and demands a release
            #    older than ~28 years. The pinned prisma CLI is a 2024 release
            #    and well outside any reasonable cooldown, so override here.
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

# 4b. claude-run (install-if-missing via bun; skipped in harden-only — LiteLLM
# isn't local, so its log-viewer service is moot too).
if [ "$HARDEN_ONLY" != "true" ]; then
    if [ -L "${HOME}/.bun/bin/claude-run" ] || [ -x "${HOME}/.bun/bin/claude-run" ]; then
        log "claude-run already installed — skipping"
    else
        log "Installing claude-run..."
        bun add -g claude-run
    fi
fi

# 4c. Claude Code (install-if-missing via official installer; runs in all modes)
if command -v claude &>/dev/null || [ -x "${HOME}/.local/bin/claude" ]; then
    log "Claude Code already installed — skipping (use 'claude update' manually if needed)"
else
    log "Installing Claude Code..."
    curl_secure -fsSL https://claude.ai/install.sh | bash
    # Re-establish bash_profile shim (the installer can drop its own)
    ensure_managed_bash_profile
fi

# 4d. ACP adapter (install-if-missing; skipped in router-only and harden-only —
# IDE integration belongs with full Claude Code installs).
if [ "$ROUTER_ONLY" != "true" ] && [ "$HARDEN_ONLY" != "true" ]; then
    ACP_PACKAGE="@agentclientprotocol/claude-agent-acp"
    if [ -L "${HOME}/.bun/bin/claude-agent-acp" ] || [ -x "${HOME}/.bun/bin/claude-agent-acp" ]; then
        log "ACP adapter already installed — skipping"
    else
        log "Installing ACP adapter (${ACP_PACKAGE})..."
        bun add -g "$ACP_PACKAGE" || warn "ACP adapter install failed, continuing"
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
update_profile_export "ANTHROPIC_BASE_URL"   "$ANTHROPIC_GATEWAY_URL"
update_profile_export "ANTHROPIC_AUTH_TOKEN" "$ANTHROPIC_AUTH_TOKEN"

# Default model selectors + gateway discovery. In ~/.profile (not managed-settings)
# so they apply in --router-only too. Values are the upstream provider-prefixed
# ids surfaced by litellm-config.yaml when Azure creds are supplied. When the
# user leaves Azure blank in .env, write empty values (unless a prior re-run /
# manual edit already set them) and emit a banner at end-of-script telling the
# user to add a model via /ui and fill these in. CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1
# is always on so any `claude-*` model added later via /ui auto-appears in
# /model. See CLAUDE.md > "Model naming".
NEEDS_MODEL_CONFIG=0
if [ -n "${AZURE_OPENAI_API_KEY:-}" ] && [ -n "${AZURE_RESOURCE_ENDPOINT:-}" ]; then
    update_profile_export "ANTHROPIC_DEFAULT_HAIKU_MODEL"  "azure/gpt-5.4-mini"
    update_profile_export "ANTHROPIC_DEFAULT_SONNET_MODEL" "azure/gpt-5.4"
    update_profile_export "ANTHROPIC_DEFAULT_OPUS_MODEL"   "azure/gpt-5.4"
else
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

# Subprocess env scrubbing: kept in ~/.profile (not managed-settings) so users
# can `unset CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` before `claude --dangerously-skip-permissions`
# when they need provider env vars to reach spawned subprocesses.
update_profile_export "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB" "1"

# Telemetry opt-outs (shell-wide; Claude-Code-specific opt-outs are in managed-settings)
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

# Scrub IS_DEMO=1 from ~/.profile if a prior tool / demo container left it
# behind. Claude Code treats it as a "demo session" marker that silently
# suppresses the workspace-trust prompt without granting trust, breaking
# statusline + hooks (anthropics/claude-code #37780).
remove_profile_export "IS_DEMO"

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
        systemctl is-enabled --quiet postgresql 2>/dev/null || sudo systemctl enable postgresql
        systemctl is-active --quiet postgresql || sudo systemctl start postgresql

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

        LITELLM_DB_URL="postgresql://litellm:${LITELLM_DB_PASSWORD}@127.0.0.1:5432/litellm"
    fi

    LITELLM_ENV_CONTENT+="DATABASE_URL=${LITELLM_DB_URL}"$'\n'
    LITELLM_ENV_CONTENT+="STORE_MODEL_IN_DB=True"$'\n'
    [ -n "${LITELLM_DB_PASSWORD:-}" ] && LITELLM_ENV_CONTENT+="LITELLM_DB_PASSWORD=${LITELLM_DB_PASSWORD}"$'\n'

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

# Enable systemd --user lingering so user services (litellm, claude-history)
# run without an active session. Needed in every mode.
if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
    sudo loginctl enable-linger "$USER" 2>/dev/null || warn "Could not enable lingering for $USER"
    sleep 2
fi

if [ "$HARDEN_ONLY" != "true" ]; then
    log "=== Phase 7: LiteLLM ==="

    LITELLM_APP_DIR="${HOME}/.config/litellm"
    LITELLM_CONFIG_FILE="${LITELLM_APP_DIR}/config.yaml"

    deploy_config "$SCRIPT_DIR/configs/litellm-config.yaml" "$LITELLM_CONFIG_FILE"

    log "LiteLLM config deployed to $LITELLM_APP_DIR"

    deploy_user_systemd_service litellm "$SCRIPT_DIR/systemd/litellm.service" \
        -e "s|__LITELLM_BIN__|${LITELLM_BIN}|g" \
        -e "s|__APP_DIR__|${LITELLM_APP_DIR}|g" \
        -e "s|__PORT__|${LITELLM_PORT}|g" \
        -e "s|__ENV_FILE__|${LITELLM_ENV_FILE}|g" \
        -e "s|__PATH__|${LITELLM_PATH}|g" || true

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

# 8a + 8b: system-level hardening (managed-settings + sandbox prereq). Skipped
# in --router-only — that mode opts out of system-wide policy enforcement.
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

    # 8b. /tmp/claude (sandbox prerequisite; bashrc-ct.sh is gone, do it here)
    mkdir -p /tmp/claude
    chmod 755 /tmp/claude
fi

# 8c + 8d: user-level state — runs in every mode (8a/8b are root-only).

# 8c. User settings. Deploy only on a fresh install — once Claude Code is
# running it owns this file (theme, plugins, accepted-bypass state); a
# re-run of setup must not clobber it.
if [ ! -f "${HOME}/.claude/settings.json" ]; then
    deploy_config "$SCRIPT_DIR/configs/claude-settings.json" "${HOME}/.claude/settings.json"
fi

# 8d. Statusline script
install -m 755 "$SCRIPT_DIR/scripts/statusline.sh" "${HOME}/.claude/statusline.sh"

log "Claude Code settings deployed"

#############################################################################
# PHASE 9: claude-history Web UI Service
#############################################################################

if [ "$HARDEN_ONLY" != "true" ]; then
    log "=== Phase 9: claude-history ==="

    CLAUDE_RUN_BIN="${HOME}/.bun/bin/claude-run"

    # Pre-create projects dir so claude-run's chokidar watcher has an inode
    mkdir -p "${HOME}/.claude/projects"
    chmod 700 "${HOME}/.claude/projects"

    deploy_user_systemd_service claude-history "$SCRIPT_DIR/systemd/claude-history.service" \
        -e "s|__CLAUDE_RUN_BIN__|${CLAUDE_RUN_BIN}|g" \
        -e "s|__CLAUDE_RUN_PORT__|${CLAUDE_RUN_PORT}|g" \
        -e "s|__PATH__|${CLAUDE_RUN_PATH}|g" || true

    systemctl --user enable claude-history &>/dev/null || true
    systemctl --user restart claude-history || warn "Failed to start claude-history"
fi

#############################################################################
# PHASE 10: APT cleanup
#############################################################################

log "=== Phase 10: Cleanup ==="

sudo apt-get autoremove -y

#############################################################################
# Done
#############################################################################

# Final safety net for bash_profile shim (curl-pipe installers can clobber it)
ensure_managed_bash_profile

log "claude-litellm setup complete!"
if [ "$HARDEN_ONLY" != "true" ]; then
    log "  LiteLLM UI:  http://127.0.0.1:${LITELLM_PORT}/ui/"
    log "  History UI:  http://127.0.0.1:${CLAUDE_RUN_PORT}"
fi
log ""
log "Open a new shell (or 'source ~/.profile') to get the env vars."
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
    echo -e "    3. ${GREEN}source ~/.profile${NC} (or open a new shell) before \`claude\`."
    echo -e "${YELLOW}${rule}${NC}"
    echo ""
fi

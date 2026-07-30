#!/bin/bash
#
# claude-litellm setup script
#
# Sets up LiteLLM gateway + (optionally) Claude Code on Debian/Kali Linux.
# Runs as the current $USER. Idempotent. Core tools (bun, uv, LiteLLM, Claude
# Code, blaude) upgrade in place on every run; everything else is
# install-if-missing (see CLAUDE.md > Key Conventions).
#
# Usage:
#   ./linux/setup.sh                  # Full setup: LiteLLM + Claude Code + managed settings
#   ./linux/setup.sh --router-only    # LiteLLM gateway + Claude Code, no managed-settings hardening
#   ./linux/setup.sh --harden-only    # Only Claude Code + managed settings (no LiteLLM; remote router)
#   ./linux/setup.sh --install-only   # Claude Code + hardening env vars only — no LiteLLM/Postgres, no gateway wiring, no managed-settings
#   ./linux/setup.sh --install-obsidian  # Also install the ACP adapter + latest Obsidian (.deb); combinable with any mode
#   ./linux/setup.sh --docker         # Run LiteLLM via rootless Docker Compose (Postgres stays on the host); additive
#
# --router-only, --harden-only, and --install-only are mutually exclusive.
# --install-obsidian and --docker are additive (combinable with any mode except
# --docker + --harden-only / --install-only, which have no LiteLLM). Flags are NOT
# persisted — each invocation is fresh; rerunning without a flag falls through to
# full mode.

set -e

# Deterministic tool output for the parsing below (dpkg-query, pg_lsclusters,
# git, loginctl) on non-English-locale boxes. Script-internal only — never
# written to ~/.profile, so the user's interactive locale is untouched.
# C.UTF-8 is built into glibc on Debian/Kali. Mirrors /opt/linux-setup.
export LC_ALL=C.UTF-8 LANG=C.UTF-8

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/common.sh"

#############################################################################
# Parse Arguments
#############################################################################

ROUTER_ONLY=false
HARDEN_ONLY=false
INSTALL_ONLY=false
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
        --install-only)
            INSTALL_ONLY=true
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
            # Deprecated no-op: setup never prompts, so the flag never did
            # anything. Still accepted (not an error) because external callers
            # (e.g. ct-dfir-llm) pass it, and Phase 0's self-update re-execs
            # with the original arguments — an unknown-arg error here would
            # brick those invocations mid-update.
            warn "--yes is deprecated and ignored (setup has no prompts)"
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

# --router-only / --harden-only / --install-only are standalone modes: at most one.
standalone_modes=0
[ "$ROUTER_ONLY" = "true" ] && standalone_modes=$((standalone_modes + 1))
[ "$HARDEN_ONLY" = "true" ] && standalone_modes=$((standalone_modes + 1))
[ "$INSTALL_ONLY" = "true" ] && standalone_modes=$((standalone_modes + 1))
if [ "$standalone_modes" -gt 1 ]; then
    error "--router-only, --harden-only, and --install-only are mutually exclusive"
    exit 1
fi

# --docker dockerizes LiteLLM; --harden-only / --install-only install no LiteLLM at all.
if [ "$DOCKER_MODE" = "true" ] && { [ "$HARDEN_ONLY" = "true" ] || [ "$INSTALL_ONLY" = "true" ]; }; then
    error "--docker is incompatible with --harden-only / --install-only (neither installs LiteLLM)"
    exit 1
fi

# Derived mode capabilities — the per-phase skip matrix in one place (CLAUDE.md >
# Setup Phases documents the same matrix in prose). Each phase tests exactly one
# of these instead of re-deriving flag combinations:
#   WITH_LOCAL_LITELLM  install + run LiteLLM/Postgres on this box (4a, 5b, 6, 7, UI banners)
#   WITH_POLICY         apply system policy: managed-settings, nah, subprocess scrub (8a, 8e, 5a scrub)
#   WITH_GATEWAY        wire Claude Code to a gateway: master key, ANTHROPIC_* vars, model selectors (5a)
#   SANDBOX_DEFAULT_ON  fresh user settings ship sandbox.enabled=true (8c seed + banner). Same
#                       set as WITH_POLICY today, but named separately: shipping the sandbox on
#                       is a different decision than enforcing system policy.
# Phases gated on a single raw flag (Phase 9's HARDEN_ONLY, the DOCKER_MODE
# branches, mode-specific banner text) stay on that flag — these booleans only
# replace the flag *combinations*.
WITH_LOCAL_LITELLM=true
{ [ "$HARDEN_ONLY" = "true" ] || [ "$INSTALL_ONLY" = "true" ]; } && WITH_LOCAL_LITELLM=false
WITH_POLICY=true
{ [ "$ROUTER_ONLY" = "true" ] || [ "$INSTALL_ONLY" = "true" ]; } && WITH_POLICY=false
WITH_GATEWAY=true
[ "$INSTALL_ONLY" = "true" ] && WITH_GATEWAY=false
SANDBOX_DEFAULT_ON=$WITH_POLICY

# We expect to run as a regular user, not root.
if [ "$EUID" -eq 0 ]; then
    warn "Running as root is not recommended. Run it as your normal user; sudo is invoked where needed."
fi

if [ "$HARDEN_ONLY" = "true" ]; then
    log "claude-litellm setup starting (--harden-only mode)"
elif [ "$ROUTER_ONLY" = "true" ]; then
    log "claude-litellm setup starting (--router-only mode)"
elif [ "$INSTALL_ONLY" = "true" ]; then
    log "claude-litellm setup starting (--install-only mode)"
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
USER_TOOL_PATH="${HOME}/.local/bin:${HOME}/.bun/bin:/usr/local/bin:/usr/bin:/bin"
# uv tool venv bin first: `prisma` CLI lives there (we install via --with prisma),
# and LiteLLM shells out to `prisma migrate deploy` on startup. Without this,
# migrations silently fail and UI-required tables like LiteLLM_UserTable never get created.
# Kept separate from USER_TOOL_PATH: the venv exposes generic names (httpx,
# openai, fastapi, nodeenv, mcp, …) that would shadow system tools for unrelated
# services.
LITELLM_PATH="${HOME}/.local/share/uv/tools/litellm/bin:${USER_TOOL_PATH}"
# The uv requirement string for LiteLLM — one definition for the fresh-install
# and upgrade paths in Phase 4a, so a floor bump can't skew the two.
LITELLM_SPEC='litellm[proxy,proxy-runtime]>=1.84.0'
# LiteLLM runtime state directory. config.yaml, the env file, and (under
# --docker) docker-compose.yml MUST stay siblings here: the docker unit's
# WorkingDirectory points at this dir and the compose file mounts ./config.yaml
# and ./env relative to it.
LITELLM_CONFIG_DIR="${HOME}/.config/litellm"
LITELLM_ENV_FILE="${LITELLM_CONFIG_DIR}/env"
LITELLM_CONFIG_FILE="${LITELLM_CONFIG_DIR}/config.yaml"
# Rootless Docker daemon socket (used by the --docker paths in Phase 7).
DOCKER_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/docker.sock"

# docker against the rootless daemon — keeps the DOCKER_HOST pinning (rootless
# socket, not the default CLI context) in one place. Used by the --docker paths
# in Phase 7.
rootless_docker() {
    DOCKER_HOST="unix://${DOCKER_SOCK}" docker "$@"
}
# docker compose against the deployed compose file.
litellm_compose() {
    rootless_docker compose -f "${LITELLM_CONFIG_DIR}/docker-compose.yml" "$@"
}

# Claude Code presence — the installer usually puts `claude` on PATH, but a
# fresh install in this same run may only exist at ~/.local/bin yet.
have_claude() {
    command -v claude &>/dev/null || [ -x "${HOME}/.local/bin/claude" ]
}

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
# default (Phase 8c sets enabled:false, block kept), but we still install the runtime
# so a user can opt in via /sandbox in the UI without re-running apt. The packages are
# tiny + benign. ripgrep is an undocumented /sandbox dep: the Mode/Overrides toggle
# tabs only render once every sandbox dependency resolves, and if Claude Code's
# bundled rg isn't found (it has regressed to a shell-shim before,
# anthropics/claude-code#31804, #31708) the user gets a deps-only screen with nothing
# to toggle. A real rg binary keeps it reachable.
APT_PACKAGES="$APT_PACKAGES bubblewrap socat ripgrep"

export DEBIAN_FRONTEND=noninteractive
# Skip the apt round-trip when every package is already installed — the common
# case on a re-run. Later apt installs (2b, 4d, 6) go through apt_install in
# common.sh: the index is refreshed at most once per run (2b forces its own
# re-index after adding the Docker repo) and APT_CHANGED feeds Phase 11's
# autoremove gate.
apt_missing=""
for pkg in $APT_PACKAGES; do
    pkg_installed "$pkg" || apt_missing="$apt_missing $pkg"
done
if [ -n "$apt_missing" ]; then
    # shellcheck disable=SC2086
    apt_install $apt_missing
    log "System packages installed:$apt_missing"
else
    log "System packages already installed: $APT_PACKAGES"
fi

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
# PHASE 3: bun + uv (install or upgrade in place)
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
    # `|| true`: write_if_changed returns 1 on unchanged content, which would
    # abort the script under `set -e` on every re-run.
    write_if_changed "${HOME}/.bun/bin/npx" 755 << NPX_EOF || true
#!/bin/sh
exec "${HOME}/.bun/bin/bun" x "\$@"
NPX_EOF
fi

# Ensure PATH entry for bun + uv in profile (idempotent)
ensure_path_in_profile 'export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"'

# Source PATH for the rest of this script
export PATH="${HOME}/.bun/bin:${HOME}/.local/bin:${PATH}"

log "bun + uv ready"

#############################################################################
# PHASE 4: Tools (LiteLLM, Claude Code, optional ACP)
#############################################################################

log "=== Phase 4: Tools ==="

# 4a. LiteLLM via uv tool install (fresh install, or upgrade in place when
# already present). uv was installed in
# Phase 3. Floor at >=1.84.0 (a floor, not a hard pin — fresh installs still get
# the latest, and a dependency cooldown picks the newest aged-in release). This
# floor sits above the compromised 1.82.7/1.82.8 PyPI releases (credential-
# stealing malware; see Anthropic's Claude Code LLM-gateway docs), so the old
# explicit `!=` excludes are no longer needed. It also guarantees the reasoning
# support this setup relies on for Azure GPT-5.6 thinking: the Anthropic
# /v1/messages -> Responses adapter honours output_config.effort (verified present
# at the 1.84.0 tag). The chat->Responses auto-route (1.83.0+) is no longer the
# mechanism — the `openai/` route in litellm-config.yaml takes the dedicated
# adapter instead. See CLAUDE.md > "Model naming" > "Why the openai/ route".
LITELLM_BIN="${HOME}/.local/bin/litellm"

# uv tool list's version column for litellm — read before/after the upgrade to
# gate the Prisma client regen on a real version change.
litellm_tool_version() {
    uv tool list 2>/dev/null | awk '$1=="litellm"{print $2; exit}'
}

# Skipped under --docker: the ghcr.io/berriai/litellm image already bundles
# LiteLLM + a generated Prisma client, so neither the uv tool install nor the
# `prisma generate` step below is needed. Skipped under --install-only too (that
# mode installs no local LiteLLM).
if [ "$WITH_LOCAL_LITELLM" = "true" ] && [ "$DOCKER_MODE" != "true" ]; then
    if [ -x "$LITELLM_BIN" ]; then
        # Upgrade-in-place (not skip): re-asserts the >=1.84.0 floor so an existing
        # install is lifted off a compromised 1.82.7/1.82.8 and picks up newer
        # aged-in releases. "Newest" stays aged-in (not bleeding-edge) because the
        # user-level ~/.config/uv/uv.toml `exclude-newer` cooldown shipped by the
        # external hardening repo applies to this resolution too. The litellm.service
        # (re)start in the systemd step below loads the new version; the Prisma client
        # is force-regenerated against the (possibly new) schema only when the version
        # ACTUALLY changed — see LITELLM_UPGRADED below.
        litellm_ver_before="$(litellm_tool_version)"
        log "LiteLLM present at $LITELLM_BIN (${litellm_ver_before:-unknown}) — upgrading (re-asserts >=1.84.0 floor)..."
        if uv tool install --upgrade --with prisma "$LITELLM_SPEC"; then
            # `uv tool install --upgrade` returns 0 even on a no-op (already at the
            # newest aged-in release), so gating the Prisma regen on its exit code
            # alone regenerated the client on EVERY re-run (the "skip" branch below
            # was dead). Gate on a real version change instead. If either version
            # read is empty (parse failed / format changed), fall back to
            # regenerating — the safe choice.
            litellm_ver_after="$(litellm_tool_version)"
            if [ "$litellm_ver_before" != "$litellm_ver_after" ]; then
                LITELLM_UPGRADED=1
                log "LiteLLM upgraded ${litellm_ver_before:-?} -> ${litellm_ver_after:-?}"
            elif [ -z "$litellm_ver_before" ]; then
                LITELLM_UPGRADED=1   # version unreadable (both empty) → regenerate to be safe
            else
                log "LiteLLM already at ${litellm_ver_after} (newest aged-in) — Prisma client regen not needed"
            fi
        else
            warn "LiteLLM upgrade failed — keeping existing version"
        fi
    else
        log "Installing LiteLLM via uv tool install..."
        uv tool install --with prisma "$LITELLM_SPEC"
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
            #  - npm_config_min_release_age=7: prisma generate spawns
            #    `npm install prisma@<pinned>` via nodeenv. npm's
            #    `min-release-age` cooldown (npm 11.10.0+) is counted in DAYS,
            #    unlike pnpm/yarn (minutes) or bun (seconds). A user's ~/.npmrc
            #    may set it: the supply-chain hardening repo ships
            #    `min-release-age=7` (7 days), but an older revision shipped a
            #    stale `10080` (intended as pnpm-style minutes) which npm reads
            #    as ~27 years and which blocks the pinned 2024 prisma CLI.
            #    Pin 7 days here so the install is deterministic regardless of
            #    the user's config (env overrides ~/.npmrc, incl. the stale
            #    10080) while keeping the hardening repo's intended cooldown:
            #    the pinned 2024 prisma CLI clears 7 days trivially.
            #  - PATH prepend: prisma's Node CLI shells out to `prisma-client-py`
            #    (the Python generator binary), which lives in the uv tool
            #    venv. Without the prepend, the nested /bin/sh can't find it.
            PATH="${UV_LITELLM_VENV}/bin:$PATH" \
            PRISMA_BINARY_CACHE_DIR="$PRISMA_BINARY_CACHE_DIR" \
            npm_config_min_release_age=7 \
                "${UV_LITELLM_VENV}/bin/prisma" generate --schema="$LITELLM_SCHEMA"
        fi
    fi
fi

# 4b. Claude Code (official installer; upgrade in place when present; all modes)
if have_claude; then
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
    have_claude \
        || warn "Claude Code is NOT installed — 'claude' unavailable; dependent steps (e.g. MCP registration) will be skipped"
    # Re-establish bash_profile shim (the installer can drop its own).
    # `force` bypasses the memo in common.sh — the installer just ran.
    ensure_managed_bash_profile force
fi

# 4c. ACP adapter (install-if-missing). Only installed with --install-obsidian:
# the ACP bridge exists to drive Claude Code from editors like Obsidian.
if [ "$INSTALL_OBSIDIAN" = "true" ]; then
    ACP_PACKAGE="@agentclientprotocol/claude-agent-acp"
    if bun_global_present claude-agent-acp; then
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
    if pkg_installed obsidian; then
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
            # apt_install refreshes the index (once per run) before installing —
            # a .deb still resolves its dependencies from the apt index. In this
            # `||` condition failures stay non-fatal, as this block intends.
            if download_to_file "$OBSIDIAN_DEB_URL" "$OBSIDIAN_DEB" "Obsidian"; then
                apt_install "$OBSIDIAN_DEB" || warn "Obsidian install failed, continuing"
            fi
            rm -f "$OBSIDIAN_DEB"
        fi
    fi
fi

# 4e. blaude — bubblewrap sandbox wrapper for Claude Code (c0ffee0wl/blaude).
# Runs in ALL modes: its only deps are bwrap (Phase 2) and claude (Phase 4b),
# both installed in every mode. blaude is a rolling single-file script with no
# release tags and no self-update (`blaude update` passes through to claude), so
# we re-fetch main on every run to keep it current — same upgrade-in-place spirit
# as bun / LiteLLM / `claude update`. The osc52-clipboard companion is
# deliberately NOT installed, and no `claude` alias is set (drop-in stays opt-in).
BLAUDE_URL="https://raw.githubusercontent.com/c0ffee0wl/blaude/main/blaude"
BLAUDE_BIN="${HOME}/.local/bin/blaude"
log "Installing/updating blaude (sandbox wrapper)..."
mkdir -p "${HOME}/.local/bin"
if ! BLAUDE_TMP="$(mktemp)"; then
    warn "Could not create temp file for blaude download — skipping"
elif download_to_file "$BLAUDE_URL" "$BLAUDE_TMP" "blaude" \
        && head -n1 "$BLAUDE_TMP" | grep -q '^#!'; then
    # Atomic replace via write_if_changed: an existing working blaude is only
    # clobbered once the new copy is fully downloaded + sanity-checked
    # (non-empty, has a shebang), and an unchanged upstream leaves the binary
    # (and the end-of-run "blaude" banner hint) untouched.
    if write_if_changed "$BLAUDE_BIN" 0755 < "$BLAUDE_TMP"; then
        BLAUDE_INSTALLED=1
        log "blaude installed/updated at $BLAUDE_BIN"
    else
        log "blaude already up to date"
    fi
else
    warn "blaude download failed or invalid — keeping existing version"
fi
# Single cleanup point: write_if_changed copies stdin into its own temp file
# and never consumes this one, so the rm is needed on every path. Guarded so
# the mktemp-failure branch (empty var) is a no-op.
[ -n "${BLAUDE_TMP:-}" ] && rm -f "$BLAUDE_TMP"

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

# Canonicalize the Azure endpoint to the v1 API surface (…/openai/v1) that the
# `openai/` route in litellm-config.yaml requires. Users paste either the bare
# resource host or the full v1 URL the Foundry portal shows; both work.
# Resolved from the environment first (current shell / .env), falling back to
# ~/.profile, then re-exported so ONE canonical value feeds both the Phase 5a
# gate below and collect_litellm_provider_vars in 5b (which writes it into
# ~/.config/litellm/env).
_azure_endpoint_raw="${AZURE_RESOURCE_ENDPOINT:-$(read_profile_export "AZURE_RESOURCE_ENDPOINT")}"
if [ -n "$_azure_endpoint_raw" ]; then
    AZURE_RESOURCE_ENDPOINT="$(normalize_azure_v1_endpoint "$_azure_endpoint_raw")"
    export AZURE_RESOURCE_ENDPOINT
fi
unset _azure_endpoint_raw

# 5a. Gateway URL + telemetry → ~/.profile (client-side; runs in every mode).
# These are the single source of truth for Claude Code's connection to LiteLLM —
# managed-settings.json no longer carries ANTHROPIC_BASE_URL/AUTH_TOKEN.

# Master key resolution. LiteLLM requires a master key starting with "sk-" for
# the unified /v1/messages endpoint. Order of precedence:
#   1. ANTHROPIC_AUTH_TOKEN from .env (user-managed)
#   2. existing value in ~/.profile (preserved across reruns)
#   3. auto-generated sk-<48 hex chars> on first run
# Skipped under --install-only: no LiteLLM gateway is wired up, so there is no
# master key to mint or carry — the gateway connection vars below are skipped too.
if [ "$WITH_GATEWAY" = "true" ]; then
    if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
        ANTHROPIC_AUTH_TOKEN="$(read_profile_export ANTHROPIC_AUTH_TOKEN)"
    fi
    if [ -z "$ANTHROPIC_AUTH_TOKEN" ] || [ "$ANTHROPIC_AUTH_TOKEN" = "test" ]; then
        ANTHROPIC_AUTH_TOKEN="sk-$(openssl rand -hex 24)"
        log "Generated new LiteLLM master key (persisted to ~/.profile)"
    fi
    # A user-supplied key without the sk- prefix is carried as-is, but LiteLLM
    # requires that prefix for /v1/messages auth (.env.example documents it) —
    # warn instead of failing so the user can decide.
    [[ "$ANTHROPIC_AUTH_TOKEN" == sk-* ]] \
        || warn "ANTHROPIC_AUTH_TOKEN does not start with 'sk-' — LiteLLM rejects such keys on /v1/messages; Claude Code will get 401s until it is fixed in .env / ~/.profile"
fi

log "Writing gateway + telemetry env vars to ~/.profile..."

# Shell-wide telemetry opt-outs (not Claude Code specific)
update_profile_export "DO_NOT_TRACK"             "1"
update_profile_export "VSCODE_TELEMETRY_DISABLE" "1"
update_profile_export "VSCODE_CRASH_REPORTER_DISABLE" "1"
update_profile_export "DOTNET_CLI_TELEMETRY_OPTOUT"   "1"
update_profile_export "POWERSHELL_TELEMETRY_OPTOUT"   "1"
update_profile_export "AZURE_CORE_COLLECT_TELEMETRY"  "0"
update_profile_export "HF_HUB_DISABLE_TELEMETRY"      "1"
update_profile_export "DISABLE_GROWTHBOOK"            "1"
update_profile_export "SCARF_ANALYTICS"               "false"

# Subprocess env scrubbing: kept in ~/.profile (not managed-settings) so users
# can `unset CLAUDE_CODE_SUBPROCESS_ENV_SCRUB` before `claude --dangerously-skip-permissions`
# when they need provider env vars to reach spawned subprocesses. Skipped under
# --router-only (a dev box where Bash/MCP/hooks should keep the full env, incl. the
# gateway token) and --install-only (no gateway token to protect); removed there
# too so a box flipped from full mode is cleaned up.
if [ "$WITH_POLICY" = "true" ]; then
    update_profile_export "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB" "1"
else
    remove_profile_export "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB"
fi

# Retired mirror toggle — scrubbed BEFORE the mirror loop below so that a
# deliberate re-add to the managed env: block would win (writer runs last).
# The umbrella was replaced by its four documented components
# (DISABLE_AUTOUPDATER/FEEDBACK_COMMAND/ERROR_REPORTING/TELEMETRY): it
# disables gateway model discovery at ANY value, even "0" — presence-triggered
# (anthropics/claude-code#61112) — while the individual flags don't. It also
# gated GrowthBook fetches (#45918); DISABLE_GROWTHBOOK above still covers that.
remove_profile_export "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"

# Claude Code feature/privacy toggles — single-sourced from the managed-settings
# template's env: block (the authoritative policy artifact), so full/harden
# (managed file) and --router-only (~/.profile only) can't drift apart on adds
# or value edits. Mirrored into ~/.profile in every mode so they also reach
# subprocesses spawned by Claude Code. Anything added to that env: block lands
# here automatically — but the mirror only ACCUMULATES: when retiring a toggle
# from the env: block, also add a remove_profile_export scrub (the IS_DEMO
# pattern below) or every deployed ~/.profile keeps exporting it. The
# `VAR=$(jq …)` form aborts under `set -e` if the template is missing/invalid
# (repo-owned — fail loudly, not with silently-missing toggles).
managed_env_toggles="$(jq -r '.env | to_entries[] | "\(.key)=\(.value)"' "$SCRIPT_DIR/configs/claude-managed-settings.json")"
if [ -z "$managed_env_toggles" ]; then
    error "No env toggles found in claude-managed-settings.json — refusing to continue with an empty policy env block"
    exit 1
fi
while IFS='=' read -r toggle_var toggle_val; do
    update_profile_export "$toggle_var" "$toggle_val"
done <<< "$managed_env_toggles"

# Non-hardening toggles
update_profile_export "CLAUDE_CODE_ATTRIBUTION_HEADER"           "0"

# UX/behavior preferences (all modes). Kept in ~/.profile (user-level prefs,
# not enforced policy → user can `unset`), so they apply regardless of flags.
#   * AUTOCOMPACT_PCT_OVERRIDE: percentage of the auto-compaction window at
#     which auto-compact triggers. Currently INERT on this gateway path — it
#     only applies when compaction is proactive (cloud sessions, Sonnet/Opus
#     4.6, or CLAUDE_CODE_AUTO_COMPACT_WINDOW set — deliberately unset here;
#     see CLAUDE.md > "Model naming" for the window-var reasoning). Kept as a
#     cheap forward-compatible pref: self-activates if any condition ever
#     holds, and only *lowers* the threshold (anthropics/claude-code#31806).
#   * FORK_SUBAGENT: let Claude spawn forked subagents — a subagent that inherits
#     the full session context (same model/tools/history) instead of a fresh one.
#     `/fork` works without it (default v2.1.161+); the var additionally lets Claude
#     auto-spawn forks and routes all subagent spawns to background (already the
#     v2.1.198 default). Model-agnostic: the fork inherits the session's gateway id
#     (azure/gpt-5.6-terra) — no hardcoded claude-* id, no 404. Its advertised cost win
#     (parent prompt-cache reuse) is Anthropic-cache-specific; over LiteLLM→Azure it
#     degrades to a normal full-context request.
update_profile_export "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"          "75"
update_profile_export "CLAUDE_CODE_FORK_SUBAGENT"               "1"

# Scrub IS_DEMO=1 from ~/.profile if a prior tool / demo container left it
# behind. Claude Code treats it as a "demo session" marker that silently
# suppresses the workspace-trust prompt without granting trust, breaking
# statusline + hooks (anthropics/claude-code #37780).
remove_profile_export "IS_DEMO"

# Retired exports — scrubbed on every run (exports only accumulate; the
# IS_DEMO pattern above). The *_SUPPORTED_CAPABILITIES trio is inert behind an
# ANTHROPIC_BASE_URL gateway — the gateway protocol reference scopes it to
# CLAUDE_CODE_USE_{BEDROCK,VERTEX,FOUNDRY,MANTLE} only. Thinking needs no
# declaration (CC treats unrecognized ids as current models and sends
# thinking:{"type":"adaptive"}); effort comes from
# CLAUDE_CODE_ALWAYS_ENABLE_EFFORT below. Re-add only if this box ever moves
# to a CLAUDE_CODE_USE_* provider.
remove_profile_export "ANTHROPIC_DEFAULT_OPUS_MODEL_SUPPORTED_CAPABILITIES"
remove_profile_export "ANTHROPIC_DEFAULT_SONNET_MODEL_SUPPORTED_CAPABILITIES"
remove_profile_export "ANTHROPIC_DEFAULT_HAIKU_MODEL_SUPPORTED_CAPABILITIES"

# Default model selectors + gateway discovery + effort. In ~/.profile (not
# managed-settings) so they apply in --router-only too. Values are the upstream
# provider-prefixed ids surfaced by litellm-config.yaml when Azure creds are
# supplied. When the user leaves Azure blank in .env, write empty values
# (unless a prior re-run / manual edit already set them) and emit a banner at
# end-of-script telling the user to add a model via /ui and fill these in.
# No *_SUPPORTED_CAPABILITIES companions (scrubbed above); the full
# thinking/effort story is in CLAUDE.md > "Model naming".
NEEDS_MODEL_CONFIG=0
# Skipped entirely under --install-only: the default-model selectors point at the
# upstream provider ids that only resolve through the LiteLLM gateway, and the
# discovery + effort levers are moot with no gateway (direct Anthropic API
# recognizes its own model ids). NEEDS_MODEL_CONFIG stays 0 so its
# end-of-script banner never fires in that mode.
if [ "$WITH_GATEWAY" = "true" ]; then
    if [ -n "${AZURE_OPENAI_API_KEY:-}" ] && [ -n "${AZURE_RESOURCE_ENDPOINT:-}" ]; then
        update_profile_export "ANTHROPIC_DEFAULT_HAIKU_MODEL"  "azure/gpt-5.6-luna"
        update_profile_export "ANTHROPIC_DEFAULT_SONNET_MODEL" "azure/gpt-5.6-terra"
        update_profile_export "ANTHROPIC_DEFAULT_OPUS_MODEL"   "azure/gpt-5.6-terra"
    else
        for var in ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL; do
            existing="$(read_profile_export "$var")"
            if [ -z "$existing" ]; then
                update_profile_export "$var" ""
                NEEDS_MODEL_CONFIG=1
            fi
        done
    fi
    # Discovery: populate /model from the gateway's /v1/models (CC >=2.1.129;
    # claude-*/anthropic-* ids only; also needs LiteLLM >=1.95.0 — the
    # two-gate story is in CLAUDE.md > "Model naming").
    update_profile_export "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY" "1"
    # Effort for custom model ids — the documented gateway lever; models that
    # reject effort are still excluded by CC, so safe for /ui-added entries.
    update_profile_export "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT" "1"
else
    # Box flipped from a gateway mode → clean the gateway-only levers
    # (the SUBPROCESS_ENV_SCRUB pattern above).
    remove_profile_export "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"
    remove_profile_export "CLAUDE_CODE_ALWAYS_ENABLE_EFFORT"
fi

update_profile_export "NO_PROXY"             "127.0.0.1"
update_profile_export "API_TIMEOUT_MS"       "600000"

# Gateway connection vars — skipped under --install-only (the whole point of that
# mode: a hardened Claude Code install with no proxy wiring). Without these,
# Claude Code talks to the real Anthropic API until the user points it elsewhere.
if [ "$WITH_GATEWAY" = "true" ]; then
    update_profile_export "LITELLM_API_KEY"      "$ANTHROPIC_AUTH_TOKEN"

    update_profile_export "ANTHROPIC_BASE_URL"   "$ANTHROPIC_GATEWAY_URL"
    update_profile_export "ANTHROPIC_AUTH_TOKEN" "$ANTHROPIC_AUTH_TOKEN"
fi

# 5b. Provider secrets → in-memory env content. Auto-discovers every
# LiteLLM-relevant provider env var from current shell + ~/.profile + .env
# (sourced above). Skipped in harden-only / install-only (no local LiteLLM).
if [ "$WITH_LOCAL_LITELLM" = "true" ]; then
    LITELLM_ENV_CONTENT="LITELLM_MASTER_KEY=${ANTHROPIC_AUTH_TOKEN}"$'\n'
    LITELLM_ENV_CONTENT+="$(collect_litellm_provider_vars)"$'\n'
fi

#############################################################################
# PHASE 6: Postgres backing store + write LiteLLM env file
#############################################################################

# LiteLLM needs Postgres + STORE_MODEL_IN_DB=True to let users add models via
# /ui. Skipped in harden-only / install-only (no local LiteLLM). If DATABASE_URL
# was supplied in .env (now in current env), we trust the user's external Postgres
# and only skip the local apt install + role/db creation.
#
# LITELLM_CHANGED collects every signal that the running service is stale (env
# file, config, unit, binary upgrade, runtime switch) — Phase 7 restarts only
# when one fired, so a no-op re-run doesn't reboot LiteLLM (Prisma reconnect +
# model-map refetch) and drop in-flight gateway connections for nothing.
# Seeded from Phase 4a's upgrade signal (a new binary needs a restart too).
LITELLM_CHANGED="${LITELLM_UPGRADED:-0}"
if [ "$WITH_LOCAL_LITELLM" = "true" ]; then
    log "=== Phase 6: Postgres ==="

    # Preserve the auto-generated DB password and any manual UI_USERNAME /
    # UI_PASSWORD overrides (.env.example documents setting those by hand)
    # across reruns — this phase regenerates the env file wholesale below, and
    # the provider-var collector deliberately excludes UI_*. Selective greps
    # rather than `source $LITELLM_ENV_FILE` because the latter would let stale
    # provider secrets in the env file shadow fresh values from .env.
    PERSISTED_DB_PASSWORD=""
    PERSISTED_UI_LINES=""
    if [ -f "$LITELLM_ENV_FILE" ]; then
        PERSISTED_DB_PASSWORD="$(grep '^LITELLM_DB_PASSWORD=' "$LITELLM_ENV_FILE" 2>/dev/null | cut -d= -f2-)"
        PERSISTED_UI_LINES="$(grep -E '^UI_(USERNAME|PASSWORD)=' "$LITELLM_ENV_FILE" 2>/dev/null || true)"
    fi

    if [ -n "${DATABASE_URL:-}" ] && [[ "${DATABASE_URL}" != postgresql://litellm:*@127.0.0.1:* ]]; then
        log "DATABASE_URL set externally — skipping local Postgres install"
        LITELLM_DB_URL="$DATABASE_URL"
    else
        if ! command -v psql &>/dev/null; then
            log "Installing postgresql via apt..."
            apt_install postgresql
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
    # Manual UI_USERNAME / UI_PASSWORD overrides survive the wholesale rewrite
    # (grepped from the previous env file at the top of this phase).
    [ -n "$PERSISTED_UI_LINES" ] && LITELLM_ENV_CONTENT+="${PERSISTED_UI_LINES}"$'\n'

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

    mkdir -p "$LITELLM_CONFIG_DIR"
    if printf '%s' "$LITELLM_ENV_CONTENT" | write_if_changed "$LITELLM_ENV_FILE" 600; then
        log "LiteLLM env file updated"
        LITELLM_CHANGED=1
    else
        log "LiteLLM env file unchanged"
    fi
fi

#############################################################################
# PHASE 7: LiteLLM config + service
#############################################################################

# (systemd --user lingering is enabled earlier, before Phase 2b.)
# Skipped in harden-only / install-only (no local LiteLLM service).
if [ "$WITH_LOCAL_LITELLM" = "true" ]; then
    log "=== Phase 7: LiteLLM ==="

    if write_if_changed "$LITELLM_CONFIG_FILE" 644 < "$SCRIPT_DIR/configs/litellm-config.yaml"; then
        LITELLM_CHANGED=1
    fi

    log "LiteLLM config deployed to $LITELLM_CONFIG_DIR"

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
        # Anchor on the ExecStart line, not the whole file: a comment mentioning
        # "docker compose" in the native template must not fake a runtime switch.
        grep -q '^ExecStart=.*docker compose' "$INSTALLED_LITELLM_UNIT" && installed_litellm_variant="docker"
        desired_litellm_variant="native"
        [ "$DOCKER_MODE" = "true" ] && desired_litellm_variant="docker"
        if [ "$installed_litellm_variant" != "$desired_litellm_variant" ]; then
            log "Switching LiteLLM runtime ${installed_litellm_variant} -> ${desired_litellm_variant}; stopping current unit first"
            LITELLM_CHANGED=1
            stop_user_service_if_active litellm
            # systemd may read the unit inactive while the rootless daemon still
            # runs the container (restart: unless-stopped), so the ExecStop above
            # never fired and an orphan still holds 127.0.0.1:4000 — fatal for a
            # docker->native switch (the native proxy can't bind). Tear the compose
            # project down directly, independent of the unit state. Idempotent; if
            # the daemon/socket is down there's no running container to orphan.
            if [ "$installed_litellm_variant" = "docker" ] && [ -f "${LITELLM_CONFIG_DIR}/docker-compose.yml" ]; then
                litellm_compose down --remove-orphans 2>/dev/null || true
            fi
        fi
    fi

    if [ "$DOCKER_MODE" = "true" ]; then
        # Dockerized LiteLLM: render the compose template (__PORT__) next to
        # config.yaml + env (the unit's WorkingDirectory is __APP_DIR__, so
        # `docker compose` auto-discovers docker-compose.yml and the relative
        # ./config.yaml + ./env mounts). The systemd --user unit runs
        # `docker compose up` against the rootless daemon. Postgres +
        # claude-devtools stay native.
        if sed -e "s|__PORT__|${LITELLM_PORT}|g" "$SCRIPT_DIR/configs/litellm-docker-compose.yml" \
            | write_if_changed "${LITELLM_CONFIG_DIR}/docker-compose.yml"; then
            LITELLM_CHANGED=1
        fi
        log "LiteLLM docker-compose deployed to ${LITELLM_CONFIG_DIR}/docker-compose.yml"

        if deploy_user_systemd_service litellm "$SCRIPT_DIR/systemd/litellm-docker.service" \
            -e "s|__APP_DIR__|${LITELLM_CONFIG_DIR}|g" \
            -e "s|__PATH__|${USER_TOOL_PATH}|g"; then
            LITELLM_CHANGED=1
        fi

        # Pre-pull the image in the foreground (visible progress) so the unit
        # start below is fast and wait_for_litellm's 90s window isn't eaten by a
        # ~367MB first-run download — the unit's ExecStartPre would otherwise pull
        # silently while we poll. The image tag is pinned, so once cached there is
        # nothing to fetch — skip the registry round-trip entirely (a tag bump
        # changes the rendered compose, the inspect misses, and the pull fires).
        # Talks to the rootless daemon started in Phase 2b.
        compose_image=$(awk '/^[[:space:]]*image:/{print $2; exit}' "${LITELLM_CONFIG_DIR}/docker-compose.yml")
        if [ -n "$compose_image" ] \
            && rootless_docker image inspect "$compose_image" &>/dev/null; then
            log "LiteLLM image ${compose_image} already cached — skipping pull"
        else
            log "Pulling LiteLLM image (first run downloads ~367MB; cached afterwards)..."
            litellm_compose pull \
                || warn "docker compose pull failed — the unit will retry via ExecStartPre on start"
        fi
    else
        if deploy_user_systemd_service litellm "$SCRIPT_DIR/systemd/litellm.service" \
            -e "s|__LITELLM_BIN__|${LITELLM_BIN}|g" \
            -e "s|__APP_DIR__|${LITELLM_CONFIG_DIR}|g" \
            -e "s|__PORT__|${LITELLM_PORT}|g" \
            -e "s|__ENV_FILE__|${LITELLM_ENV_FILE}|g" \
            -e "s|__PATH__|${LITELLM_PATH}|g"; then
            LITELLM_CHANGED=1
        fi
    fi

    # Enable + restart only when something the service consumes actually
    # changed (env file, config, unit, compose render, binary upgrade, runtime
    # switch) — an unconditional restart made every no-op re-run reboot
    # LiteLLM (Prisma reconnect + boot-time model-map fetch, 5-25s) and drop
    # in-flight gateway connections. Called bare: a failed restart aborts
    # under `set -e`.
    restart_user_service_if_stale litellm "$LITELLM_CHANGED"

    wait_for_litellm "$LITELLM_PORT" || warn "LiteLLM may not be ready — Claude Code calls could fail until it starts"
fi

#############################################################################
# PHASE 8: Claude Code Managed Settings (only in full mode)
#############################################################################

log "=== Phase 8: Claude Code Settings ==="

# 8a: system-level hardening (managed-settings). Skipped in --router-only and
# --install-only — both opt out of system-wide policy enforcement.
if [ "$WITH_POLICY" = "true" ]; then
    # 8a. Managed settings (system-level, root-owned). Token-substitute __REPO_DIR__
    # in hooks paths; install only on change so the root-owned policy file keeps
    # its mtime/inode across no-op re-runs (same idempotency contract as every
    # other deploy — the installed copy is world-readable, so cmp works unprivileged).
    sudo install -d -m 755 /etc/claude-code

    MANAGED_TMP=$(mktemp)
    sed \
        -e "s|__REPO_DIR__|${REPO_DIR}|g" \
        "$SCRIPT_DIR/configs/claude-managed-settings.json" > "$MANAGED_TMP"

    if cmp -s "$MANAGED_TMP" /etc/claude-code/managed-settings.json 2>/dev/null; then
        log "Managed settings unchanged at /etc/claude-code/managed-settings.json"
    else
        sudo install -m 644 -o root -g root "$MANAGED_TMP" /etc/claude-code/managed-settings.json
        log "Managed settings deployed to /etc/claude-code/managed-settings.json"
    fi
    rm -f "$MANAGED_TMP"
fi

# 8b. /tmp/claude (sandbox prerequisite; bashrc-ct.sh is gone, do it here). Runs in
# every mode — no sudo needed, and the sandbox runtime now ships in all modes (incl.
# --router-only, which can /sandbox on), so the prereq dir must exist everywhere.
mkdir -p /tmp/claude
# Non-fatal: on a multi-user host the dir may already exist owned by someone
# else (sticky /tmp lets mkdir -p succeed but chmod EPERM), which must not
# abort setup under `set -e`.
chmod 755 /tmp/claude 2>/dev/null \
    || warn "/tmp/claude exists but is not owned by $USER — the sandbox prereq dir may be unusable"

# 8c + 8d: user-level state — runs in every mode (8a is root-only; 8b ran above).

# 8c. User settings. Deploy only on a fresh install — once Claude Code is
# running it owns this file (theme, plugins, accepted-bypass state); a
# re-run of setup must not clobber it.
NEEDS_SANDBOX_BLOCK=0
if [ ! -f "${HOME}/.claude/settings.json" ]; then
    if [ "$SANDBOX_DEFAULT_ON" != "true" ]; then
        # router-only / install-only ship the sandbox OFF, but KEEP the full block and
        # just set enabled:false (don't strip it). The floor (denyRead/denyWrite/network)
        # stays pre-configured, so flipping enabled:true later activates the hardened
        # sandbox with no re-config, and the statusline reflects whatever the user sets.
        # bwrap is installed in all modes (Phase 2).
        # Capture jq's output first: a bare `jq | write_if_changed` pipeline has no
        # pipefail (set -o pipefail isn't set), so a jq failure would be masked and
        # write_if_changed would write an empty settings.json and return 0. The
        # `VAR=$(jq …)` form aborts the script under `set -e` if jq fails.
        ROUTER_SETTINGS=$(jq '.sandbox.enabled = false' "$SCRIPT_DIR/configs/claude-settings.json")
        printf '%s\n' "$ROUTER_SETTINGS" \
            | write_if_changed "${HOME}/.claude/settings.json" 644
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

# 8d. Statusline script (content-aware copy — no rewrite on no-op re-runs)
deploy_config "$SCRIPT_DIR/scripts/statusline.sh" "${HOME}/.claude/statusline.sh" 755

# 8e. nah Claude Code plugin — deterministic action-aware guard. Catches
# wrapper-evasion patterns the Bash(...) deny rules in managed-settings can't
# (sh -c, python -c, xargs rm, find -delete, git push -f short-form, …) by
# classifying commands into action types (filesystem_delete, lang_exec,
# git_history_rewrite, …) and resolving allow/ask/block with sensitive-path
# + content-scan context. Skipped under --router-only and --install-only (no
# policy enforcement in those modes). PreToolUse hooks still fire under --dangerously-skip-permissions
# per Anthropic docs — the flag skips the deny/ask/allow rule chain and the
# user prompt, but hooks run *before* the prompt and remain active, so nah
# is the only active policy layer in that mode (and `permissions.deny[]` is
# idle). Marketplace ref uses @claude-marketplace branch (where upstream's
# marketplace.json lives) and is otherwise unpinned — same install-if-missing-
# then-latest convention as ACP (4c); user runs
# `claude plugin update nah --scope user` to upgrade.
if [ "$WITH_POLICY" = "true" ] && have_claude; then
    # Every claude invocation here needs stdin redirected + a timeout so a
    # headless/CI run can't wedge the script. Two independent hazards, two guards:
    #
    #   1. TTY probing (the real wedger). `claude` is a Node TUI: when its
    #      stdout is an interactive terminal it emits terminal-capability
    #      queries (OSC 11 background-colour, DA1 device-attributes) AFTER
    #      doing its work and blocks waiting for the replies — which arrive on
    #      stdin, but stdin is </dev/null here, so they never come and it hangs
    #      forever (it has already printed "Successfully installed", so the
    #      on-disk action is done). The read-only calls dodge this for free by
    #      piping stdout into tr|sed|jq — a pipe is not a tty, so isTTY is
    #      false and claude stays non-interactive. The mutating calls get the
    #      same via claude_mutate below ($(... 2>&1) capture makes stdout/stderr
    #      pipes, not the terminal); output is surfaced only on failure.
    #   2. timeout signal escalation (belt-and-suspenders). Plain `timeout N`
    #      sends only SIGTERM then waits for the child; a Node process that
    #      traps it or keeps a handle open is never killed and timeout waits
    #      forever. `-k <grace>` escalates to uncatchable SIGKILL. The
    #      add/install calls clone over the network under claude's own 120s
    #      internal git timeout, so their outer bound is 180s (above 120s) to
    #      avoid cutting a slow-but-working first clone; -k 15 force-kills 15s
    #      later. State is committed before any lingering, so a force-kill
    #      never corrupts it (re-runs find it "already added"/installed).
    #
    # Read-only queries share one sanitizer: `claude plugin … --json` (verified
    # empirically) writes JSON with CRLF line endings AND appends a trailing
    # ANSI escape `\e[?25h` (show-cursor) past the closing `]`. Strip CR with
    # `tr -d '\r'` and extract just the bracketed array with
    # `sed -n '/^\[/,/^\]/p'` so jq gets clean input. The sed range tolerates a
    # single-line `[]` (both anchors match the same line, printed once).
    claude_plugin_json() {
        timeout -k 15 60 claude "$@" --json </dev/null 2>/dev/null \
            | tr -d '\r' \
            | sed -n '/^\[/,/^\]/p'
    }

    # The mutating plugin calls below share the same hazards; this wrapper bakes
    # in all three guards (stdin closed, stderr folded into stdout for the
    # caller's $(...) capture, timeout with SIGKILL escalation) so a call site
    # can't silently drop one and reintroduce the tty-probe wedge. Scoped to
    # this WITH_POLICY block like claude_plugin_json — hoist both to the
    # top-level helper section if another phase ever needs them.
    # Usage: out=$(claude_mutate <secs> <claude-args…>)
    claude_mutate() {
        local secs="$1"
        shift
        timeout -k 15 "$secs" claude "$@" </dev/null 2>&1
    }

    # Plugin state first — the steady state (installed + enabled) then costs a
    # single claude invocation; the marketplace is only checked/added on the
    # install path, where `claude plugin install` needs it registered. A
    # marketplace the user removed while keeping the plugin installed is
    # consequently NOT re-added (it's only needed again for
    # `claude plugin update nah`).
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
    #
    # Note: `// "absent"` won't work as a fallback because jq's // operator
    # treats both null AND false as missing — so an installed-but-disabled
    # plugin (enabled: false) would silently look "absent". Use if/else.
    #
    # Defensive: stage the raw output so we can distinguish "empty output"
    # (claude crashed / subcommand missing) from "parse error" (claude
    # emitted JSON + trailing noise) from "valid output, plugin absent".
    # An ambiguous state should NOT trigger reinstall (would spam install
    # attempts on every re-run); warn and skip until the next run.
    plugin_list=$(claude_plugin_json plugin list || true)
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
            # Marketplace registration: schema (verified via `claude plugin
            # marketplace list --json`) is a bare array of { name, source, repo,
            # installLocation } — .source is the source TYPE ("github"), .repo
            # holds "owner/repo". Match on .repo for exact identity (avoids
            # fork/mirror false positives).
            nah_marketplace_ok=0
            if claude_plugin_json plugin marketplace list \
                | jq -e '.[]? | select(.repo == "manuelschipper/nah")' >/dev/null 2>&1; then
                nah_marketplace_ok=1
            else
                log "Adding nah plugin marketplace..."
                # @claude-marketplace is the git ref where marketplace.json lives in
                # the upstream repo — the default branch does not contain it, so the
                # bare `manuelschipper/nah` form fails with "marketplace.json not found".
                # The .repo field in `claude plugin marketplace list --json` drops the
                # ref suffix, so the idempotency selector above still matches.
                # if-condition form is set -e-safe (a failure doesn't abort the script).
                if nah_add_out=$(claude_mutate 180 plugin marketplace add manuelschipper/nah@claude-marketplace); then
                    nah_marketplace_ok=1
                else
                    warn "Failed to add nah marketplace — try 'claude update' (the 'plugin' subcommand may be missing in older Claude Code). Output: ${nah_add_out}"
                fi
            fi

            # Only attempt install if the marketplace is registered — otherwise
            # the install call is guaranteed to fail with a less informative error.
            if [ "$nah_marketplace_ok" = "1" ]; then
                log "Installing nah Claude Code plugin..."
                if nah_install_out=$(claude_mutate 180 plugin install nah@nah --scope user); then
                    log "nah plugin installed"
                    # install enables by default; assert it on first install so a
                    # fresh box ends up enabled regardless of build behaviour. A
                    # benign "already enabled" error here is expected and ignored.
                    # We do this ONLY on first install — never in the `false`
                    # branch, where a disabled plugin is the user's choice.
                    claude_mutate 60 plugin enable nah@nah --scope user >/dev/null || true
                else
                    warn "Failed to install nah plugin — try 'claude plugin marketplace list' to confirm marketplace registration. Output: ${nah_install_out}"
                fi
            fi
            ;;
        *)
            warn "Could not determine nah plugin state ('$nah_state') — skipping mutation; re-run setup.sh to retry"
            ;;
    esac
fi

log "Claude Code settings deployed"

#############################################################################
# PHASE 9: Claude DevTools
#############################################################################

CLAUDE_DEVTOOLS_DEPLOYED=0
CLAUDE_DEVTOOLS_RAM_OK=0
# Set when the build or the unit file actually changed — gates the service
# restart below (mirrors LITELLM_CHANGED in Phase 7).
CLAUDE_DEVTOOLS_CHANGED=0
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
    if bun_global_present pnpm; then
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
            # -e dist-standalone: keep the PREVIOUS build output through the
            # clean — a failed build below then leaves it on disk, so "build
            # failures are non-fatal, the existing build keeps serving" holds
            # across service restarts too (the build regenerates the dir
            # wholesale on success, so nothing stale survives a good build).
            if ! (cd "$CLAUDE_DEVTOOLS_DIR" && git fetch --depth 1 --no-tags origin tag "$CLAUDE_DEVTOOLS_LATEST_TAG" && git -c advice.detachedHead=false checkout --force "refs/tags/$CLAUDE_DEVTOOLS_LATEST_TAG" && git clean -fdx -e .dt-installed-tag -e dist-standalone); then
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
                    # `|| true`: write_if_changed returns 1 when the stamp already
                    # holds this tag (rebuild at an unchanged tag, e.g. after the
                    # user wiped dist-standalone/) — without it, `set -e` kills
                    # the whole script here, skipping the service deploy below
                    # plus Phases 10-11 and every end-of-run banner.
                    echo "$CLAUDE_DEVTOOLS_LATEST_TAG" | write_if_changed "$CLAUDE_DEVTOOLS_STAMP" || true
                    CLAUDE_DEVTOOLS_CHANGED=1
                    log "claude-devtools built successfully at $CLAUDE_DEVTOOLS_LATEST_TAG"
                fi
            fi
        fi
    fi

    if [ -f "$CLAUDE_DEVTOOLS_BUILD" ]; then
        if deploy_user_systemd_service claude-devtools "$SCRIPT_DIR/systemd/claude-devtools.service" \
            -e "s|__CLAUDE_DEVTOOLS_DIR__|${CLAUDE_DEVTOOLS_DIR}|g" \
            -e "s|__CLAUDE_DEVTOOLS_PORT__|${CLAUDE_DEVTOOLS_PORT}|g" \
            -e "s|__BUN_BIN__|${CLAUDE_DEVTOOLS_BUN}|g" \
            -e "s|__PATH__|${USER_TOOL_PATH}|g"; then
            CLAUDE_DEVTOOLS_CHANGED=1
        fi

        # Enable + restart only when the build or unit actually changed (a
        # no-op re-run must not bounce the service and drop open DevTools UI
        # sessions). Unlike the litellm call in Phase 7, a failure here is
        # non-fatal.
        if restart_user_service_if_stale claude-devtools "$CLAUDE_DEVTOOLS_CHANGED"; then
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
if [ -f "$LEGACY_HISTORY_SERVICE" ] || bun_global_present claude-run; then
    log "=== Phase 10: removing legacy claude-run + claude-history service ==="
    if [ -f "$LEGACY_HISTORY_SERVICE" ]; then
        systemctl --user disable --now claude-history &>/dev/null || true
        rm -f "$LEGACY_HISTORY_SERVICE"
        systemctl --user daemon-reload &>/dev/null || true
        log "Removed claude-history.service"
    fi
    if bun_global_present claude-run; then
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

# Only worth a sudo round-trip when some phase actually touched apt state.
if [ "$APT_CHANGED" = "1" ]; then
    sudo apt-get autoremove -y
else
    log "No apt changes this run — skipping autoremove"
fi

#############################################################################
# Done
#############################################################################

# Final safety net for bash_profile shim (curl-pipe installers can clobber it).
# `force` bypasses the memo — installers may have run since the last check.
ensure_managed_bash_profile force

log "claude-litellm setup complete!"
# LiteLLM UI only exists when a local LiteLLM was installed (not harden-only /
# install-only). DevTools is installed in install-only too, so print it whenever
# it deployed, regardless of mode.
if [ "$WITH_LOCAL_LITELLM" = "true" ]; then
    log "  LiteLLM UI:  http://127.0.0.1:${LITELLM_PORT}/ui/"
fi
if [ "$CLAUDE_DEVTOOLS_DEPLOYED" = "1" ]; then
    log "  DevTools UI: http://127.0.0.1:${CLAUDE_DEVTOOLS_PORT}"
fi
if [ "${BLAUDE_INSTALLED:-0}" = "1" ]; then
    log "  blaude:      sandboxed Claude Code — run 'blaude' (github.com/c0ffee0wl/blaude)"
fi
log ""
log "Log out and back in (or run 'source ~/.profile') to load the env vars — a plain new terminal won't read ~/.profile."
if [ "$HARDEN_ONLY" = "true" ]; then
    log "ANTHROPIC_BASE_URL in ~/.profile is currently: ${ANTHROPIC_GATEWAY_URL}"
    log "Edit ~/.profile (or set ANTHROPIC_GATEWAY_URL in .env and re-run) to point at your remote LiteLLM."
fi
if [ "$INSTALL_ONLY" = "true" ]; then
    log "No gateway configured (--install-only) — Claude Code will use the real Anthropic API."
    log "To route through a LiteLLM proxy, set ANTHROPIC_BASE_URL + ANTHROPIC_AUTH_TOKEN in ~/.profile."
    log "Then run 'claude' to start Claude Code."
else
    log "Then run 'claude' to start Claude Code via the LiteLLM gateway."
fi

rule="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Skip on systemd / piped runs. No LiteLLM UI/master key under install-only.
if [ "$WITH_LOCAL_LITELLM" = "true" ] && [ -t 1 ]; then
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

if [ "$NEEDS_MODEL_CONFIG" = "1" ] && [ -t 1 ]; then
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
    echo -e "    3. ${GREEN}source ~/.profile${NC} (or log out and back in) before \`claude\`."
    echo -e "${YELLOW}${rule}${NC}"
    echo ""
fi

if [ "$NEEDS_SANDBOX_BLOCK" = "1" ] && [ -t 1 ]; then
    echo -e "${YELLOW}${rule}${NC}"
    echo -e "${YELLOW}  ~/.claude/settings.json has no sandbox block — the statusline can't"
    echo -e "  detect the sandbox. Add it (keeps your other keys), then restart"
    echo -e "  Claude Code:${NC}"
    echo ""
    if [ "$SANDBOX_DEFAULT_ON" != "true" ]; then
        echo -e "    ${GREEN}${SCRIPT_DIR}/scripts/add-sandbox-block.sh --disabled${NC}"
        echo ""
        echo -e "${YELLOW}  (router-only / install-only seed it disabled — set sandbox.enabled:true to turn it on)${NC}"
    else
        echo -e "    ${GREEN}${SCRIPT_DIR}/scripts/add-sandbox-block.sh${NC}"
    fi
    echo -e "${YELLOW}${rule}${NC}"
    echo ""
fi

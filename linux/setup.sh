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
#   ./linux/setup.sh --no-profile-toggles  # Don't mirror the Claude Code toggles into ~/.profile (and scrub prior ones) — for overlays that carry them in their own managed-settings env: block
#
# --router-only, --harden-only, and --install-only are mutually exclusive.
# --install-obsidian, --docker, and --no-profile-toggles are additive (combinable
# with any mode except --docker + --harden-only / --install-only, which have no
# LiteLLM). Flags are NOT persisted — each invocation is fresh; rerunning without
# a flag falls through to full mode.

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
PROFILE_TOGGLES=true
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
        --no-profile-toggles)
            PROFILE_TOGGLES=false
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
# and LiteLLM shells out to `prisma migrate deploy` on startup
# (--use_v2_migration_resolver in the unit). Without this, the schema sync
# silently fails and UI-required tables like LiteLLM_UserTable never get created.
# Kept separate from USER_TOOL_PATH: the venv exposes generic names (httpx,
# openai, fastapi, nodeenv, mcp, …) that would shadow system tools for unrelated
# services.
LITELLM_PATH="${HOME}/.local/share/uv/tools/litellm/bin:${USER_TOOL_PATH}"
# THE LiteLLM version — one constant for BOTH runtimes: the uv spec below and
# the __LITELLM_IMAGE_TAG__ token in configs/litellm-docker-compose.yml (Phase 7
# renders it). A single source is load-bearing, not tidiness: native used to
# float on a `>=` floor while --docker was pinned, so a box could migrate the
# SHARED host DB ahead of the image tag — and flipping to --docker then meant a
# schema DOWNGRADE, the one direction that destroys data (CLAUDE.md > "DB schema
# posture"). Pinning both to the same value makes that unreachable.
#
# BUMP DELIBERATELY (same discipline as the claude-devtools release tag). Verify
# all four criteria before moving it — they diverge; recipe in CLAUDE.md:
#   1.97.0 (verified 2026-08-23): ghcr manifest 200; upstream git tag
#   ef84494d52c6708e4e9f4a54ce551a265995ad8f; the tag's committed uv.lock pins
#   fastapi 0.136.3 (so #35763 cannot reach inside the image — the check the
#   native LITELLM_FASTAPI_GUARD can't perform); image .created 2026-08-16, past
#   the uv cooldown. 1.97.1 does not exist; the 1.97 line has one release.
# Above the compromised 1.82.7/1.82.8, and 1.97.0 pins litellm-proxy-extras
# ==0.4.84 — the release whose heal_incomplete_nodeenv_cache and separate
# bootstrap budget make configs/litellm-prisma.env's LITELLM_PRISMA_* values
# live (they are inert against the 0.4.81 that litellm <=1.96.2 pins).
LITELLM_VERSION='1.97.0'
# The uv requirement string for LiteLLM — one definition for the fresh-install
# and upgrade paths in Phase 4a, so a version bump can't skew the two. An exact
# `==` pin, not a floor: see LITELLM_VERSION. `uv tool install --upgrade` is
# therefore a no-op on an already-pinned box; the Prisma regenerate gate keys
# on a provenance stamp rather than on any "did it upgrade" flag.
LITELLM_SPEC="litellm[proxy,proxy-runtime]==${LITELLM_VERSION}"
# fastapi ceiling for the LiteLLM venv: litellm >=1.95.0 crash-loops on
# fastapi >=0.140.7 (issue BerriAI/litellm#35763; full story in CLAUDE.md >
# Setup Phases > 4a). DROP once a litellm release containing upstream merge
# ecba48d has aged past the uv cooldown.
# Verify by grepping the wheel, NOT by comparing SHAs (recipe + why in CLAUDE.md).
# Checked 2026-08-23 — 1.96.2 and 1.97.0 both still import `get_flat_dependant`;
# v1.98.0 is the FIRST release importing `get_flat_params`, i.e. the release to
# move LITELLM_VERSION to in order to drop this guard.
#
# READ THE NAG'S REACH HONESTLY: LITELLM_FASTAPI_GUARD_STALE_ABOVE names the
# newest release verified broken, and Phase 4a compares it against the INSTALLED
# litellm. Since LITELLM_SPEC is an exact `==` pin, the installed version can
# only exceed the marker after a human edits LITELLM_VERSION — so the nag is a
# reminder attached to a deliberate bump, NOT an aging-in detector. Nothing
# fires on its own when a fixed litellm or a fastapi security release ships;
# re-check this pin whenever you touch LITELLM_VERSION. (Same for
# LITELLM_PYTHON_PIN_STALE_ABOVE below: prisma-client-py's version is pinned
# transitively by the litellm pin, so it too only moves on a deliberate bump.)
LITELLM_FASTAPI_GUARD='fastapi<0.140.7'
LITELLM_FASTAPI_GUARD_STALE_ABOVE='1.97.0'
# Interpreter for the LiteLLM venv. Neither package's requires-python excludes
# 3.14 (litellm >=3.10,<3.15; prisma >=3.8.0), so this cannot be derived — it is
# an explicit pin with a staleness nag, like LITELLM_FASTAPI_GUARD above.
# Why: Kali moved to Python 3.14, `uv tool install` rebuilt the venv onto it, and
# prisma-client-py 0.15.0 predates 3.14 and does not test against it. The
# `'Prisma' object has no attribute '_Prisma__engine' and no __dict__ for
# setting new attributes` seen in the field is CONSISTENT with that but was
# never confirmed — this pin is defensive, not a diagnosis. Without it a distro
# Python bump silently rebuilds the venv under the service.
# Changing the pin moves the venv path, so uv rebuilds and the Prisma stamp
# (Phase 4a) regenerates the client automatically. Where the pinned interpreter
# is absent, uv fetches a managed CPython. Override by editing this line.
LITELLM_PYTHON_PIN='3.13'
LITELLM_PYTHON_PIN_STALE_ABOVE='0.15.0'   # newest prisma-client-py verified against the pin
# The uv --with set shared by both Phase 4a install paths — one definition so
# the guard drop (or a future addition) can't skew fresh-install vs upgrade,
# same rule as LITELLM_SPEC above.
# psycopg is why this list has a third entry: it is a DEV-only dependency of
# litellm, and without it litellm-proxy-extras' _warn_if_db_ahead_of_head()
# returns silently on ImportError — the only thing that reports a DB newer than
# this build's schema. Deliberately unpinned (unlike LITELLM_SPEC): diagnostic
# only, nothing imports it at request time. It is necessary but NOT sufficient
# on this repo's socket-first Postgres — CLAUDE.md > "DB schema posture" has the
# caveat and what actually guards against a downgrade.
LITELLM_UV_WITH=(--with prisma --with 'psycopg[binary]' --with "$LITELLM_FASTAPI_GUARD")
# LiteLLM runtime state directory. config.yaml, the env file, and (under
# --docker) docker-compose.yml MUST stay siblings here: the docker unit's
# WorkingDirectory points at this dir and the compose file mounts ./config.yaml
# and ./env relative to it.
LITELLM_CONFIG_DIR="${HOME}/.config/litellm"
LITELLM_ENV_FILE="${LITELLM_CONFIG_DIR}/env"
LITELLM_CONFIG_FILE="${LITELLM_CONFIG_DIR}/config.yaml"
# Prisma toolchain files (native mode only; see the templates' comments):
# prisma.env is the single source of the PRISMA_* switches for BOTH setup.sh's
# run_prisma and the unit's EnvironmentFile=; pyproject.toml is prisma-client-py's
# per-cwd config (Node LTS pin for the nodeenv).
LITELLM_PRISMA_ENV_FILE="${LITELLM_CONFIG_DIR}/prisma.env"
LITELLM_PYPROJECT_FILE="${LITELLM_CONFIG_DIR}/pyproject.toml"
# Set by Phase 4a when the Prisma client could not be generated: the proxy
# would crash on import ("The Client hasn't been generated yet"), so every
# litellm start site (the 4a abort belt, Phase 7) leaves the unit STOPPED instead
# of feeding a 20x crash loop, and the end-of-run banner says so. Non-fatal by
# design — a broken gateway must not abort the rest of the run (or an
# overlay's remaining phases); the next run's import probe regenerates.
LITELLM_CLIENT_BROKEN=0
# Why, for the end-of-run banner: install (uv could not install/converge the
# venv — typically the pin inside the uv cooldown), toolchain (prisma.env /
# warm-up / schema lookup), generate (prisma generate failed).
LITELLM_CLIENT_BROKEN_WHY=""
# Provider endpoints Phase 7's DNS probe could not resolve, split by failure
# shape — the two have different remedies, so the end-of-run banner prints them
# as separate lists.
ENDPOINT_DNS_V4_ONLY=()
ENDPOINT_DNS_DEAD=()
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

# 4a. LiteLLM via uv tool install (fresh install, or converge in place when
# already present). uv was installed in Phase 3. The version is the exact
# LITELLM_VERSION pin, which also renders the --docker image tag — rationale and
# the four bump criteria live next to that constant. It sits above the
# compromised 1.82.7/1.82.8 PyPI releases (credential-stealing malware; see
# Anthropic's Claude Code LLM-gateway docs), so the old explicit `!=` excludes
# are no longer needed, and it guarantees the reasoning support this setup
# relies on for Azure GPT-5.6 thinking: the Anthropic /v1/messages -> Responses
# adapter honours output_config.effort (present from the 1.84.0 tag). The
# chat->Responses auto-route (1.83.0+) is no longer the mechanism — the
# `openai/` route in litellm-config.yaml takes the dedicated adapter instead.
# See CLAUDE.md > "Model naming" > "Why the openai/ route".
LITELLM_BIN="${HOME}/.local/bin/litellm"
# One name for the deployed unit path: Phase 4a keys its restore on it, Phase 7
# reads it for the native<->docker variant switch. Two independent spellings
# desynced on a rename would mask a unit the restore path then declines to
# restore.
INSTALLED_LITELLM_UNIT="$(user_unit_path litellm)"

# Clear a start-hold a killed earlier run may have left (4a holds manual starts
# of the unit across the venv rebuild — release_user_service_starts, common.sh;
# it also removes a stale runtime MASK link from the older mask-based
# revision). Unconditional and outside every mode branch on purpose: 4a's own
# release only runs in native mode, so a later --docker run would have Phase 7's
# restart refused ("unit … may be requested by dependency only") with no EXIT
# trap armed yet, and --harden-only / --install-only would leave the proxy held
# and down with no message at all. Free no-op when nothing is held; 4a re-holds
# straight after.
release_user_service_starts litellm

# Run python from the LiteLLM venv. One spelling for every probe below, so the
# venv layout is known in exactly one place.
litellm_venv_python() {
    "${UV_LITELLM_VENV}/bin/python" "$@"
}

# Installed version of any distribution inside the LiteLLM venv. Empty when
# absent or unreadable. Read from installed metadata rather than parsing
# `uv tool list` — that is a human-facing table with no stability contract, and
# an empty read here would make the Prisma provenance stamp record `unknown`
# and regenerate the client on every run. It also reaches the `--with` packages,
# which never appear in `uv tool list` at all.
litellm_venv_pkg_version() {
    litellm_venv_python -c \
        "import importlib.metadata as m; print(m.version('$1'))" 2>/dev/null || true
}

litellm_tool_version() {
    litellm_venv_pkg_version litellm
}

# Provenance of a generated Prisma client: everything that determines its shape.
# The schema hash is the core field; prisma-client-py is the GENERATOR, so a
# generator upgrade against an unchanged schema must regenerate too (otherwise
# the new library imports a client the old one emitted — the same sticky-stale
# shape one layer up). The litellm version makes the skip log readable, and the
# interpreter minor covers a venv uv rebuilt in place under a new Python.
# Both versions are PARAMETERS, not ambient reads: they are set ~200 lines below
# this definition, and a `${...:-unknown}` fallback on a call-order mistake would
# not fail loudly — it would mint a stamp that matches forever, which is exactly
# the sticky-stale bug this function exists to prevent.
# Usage: prisma_stamp_for <schema.prisma> <litellm-version> <prisma-client-py-version>
prisma_stamp_for() {
    local schema="$1" litellm_ver="$2" generator_ver="$3" pyver sha
    # Fail (empty output) rather than stamping a schema we could not read, or
    # one whose provenance we cannot fully state — the caller treats an empty
    # stamp as "regenerate", which is the safe direction.
    [ -n "$litellm_ver" ] && [ -n "$generator_ver" ] || return 1
    sha="$(sha256sum "$schema" 2>/dev/null | cut -d' ' -f1)"
    [ -n "$sha" ] || return 1
    pyver="$(litellm_venv_python -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo unknown)"
    printf '%s|%s|%s|%s\n' "$litellm_ver" "$sha" "$generator_ver" "$pyver"
}

# The venv the litellm tool lives in — needed by the toolchain work below and by
# the staleness nags above it, so it is resolved once here.
UV_LITELLM_VENV="${HOME}/.local/share/uv/tools/litellm"

# Skipped under --docker: the ghcr.io/berriai/litellm image already bundles
# LiteLLM + a generated Prisma client, so neither the uv tool install nor the
# `prisma generate` step below is needed. Skipped under --install-only too (that
# mode installs no local LiteLLM).
if [ "$WITH_LOCAL_LITELLM" = "true" ] && [ "$DOCKER_MODE" != "true" ]; then
    # Take the service down for the venv rebuild + prisma generate below: a live
    # unit restarts into the half-built venv and then races THIS script over the
    # shared ~/.cache/prisma-python/nodeenv toolchain, which is how that cache
    # ends up half-installed. Full story: CLAUDE.md > Troubleshooting, "any
    # `prisma` command hangs".
    #
    # The stop is unconditional (stop_user_service — see its docstring for why
    # an `is-active` gate skips exactly the wedged boxes this window exists
    # for, observed 2026-08-19), then manual starts are HELD for the duration
    # of the window: the stop cancels systemd's own pending restart, but
    # nothing else prevents a start commanded mid-rebuild (an operator, a
    # health-check script) from re-opening the race. The hold is a runtime
    # `RefuseManualStart=yes` drop-in, NOT `systemctl mask --runtime` — for a
    # user unit deployed under ~/.config that mask is shadowed by the unit
    # itself and blocks nothing (hold_user_service_starts, common.sh, has the
    # load-path detail). Lives in /run, so even a hard crash of this script is
    # healed by the next reboot. Holding a not-yet-deployed name (fresh
    # install) is harmless: every exit below releases before Phase 7 deploys
    # it.
    stop_user_service litellm
    hold_user_service_starts litellm

    # ABORT BELT ONLY — the normal path never starts litellm before Phase 7
    # (see the end of 4a). An unexpected `set -e` abort anywhere between here
    # and Phase 7's own start would otherwise leave the proxy down (and
    # masked) with nothing to bring it back (no timer, updates are manual).
    # Release the hold unconditionally (also clears a stale one a killed
    # earlier run left), then start an inactive unit — unless there is no unit
    # yet (fresh install: deployed in Phase 7) or no Prisma client to import
    # (starting would only burn 20 start-limit cycles of proxy import). The
    # start is `--no-block`: the unit's ExecStartPre is a ~120s pg_isready
    # loop, and the abort that armed this belt may well BE "Postgres is down"
    # (Phase 6's own exit 1 on a restored snapshot) — a blocking restart would
    # then sit out the whole gate in silence AFTER the fatal message, and the
    # proxy would still only come up when Postgres does (Restart=always keeps
    # trying, the designed boot-race behavior). So: say what is happening,
    # queue the start, exit. Phase 7 disarms it after its start. Bash has ONE
    # EXIT-trap slot: do not add another `trap … EXIT` anywhere between here
    # and that disarm — it would silently replace this belt (and be nuked by
    # the disarm in turn).
    restore_litellm_service() {
        release_user_service_starts litellm
        [ -f "$INSTALLED_LITELLM_UNIT" ] || return 0
        [ "$LITELLM_CLIENT_BROKEN" = "1" ] && return 0
        warn "setup.sh is exiting before Phase 7 — queueing a litellm start in the background (its pg_isready gate waits up to ~120s for Postgres; if Postgres is down the unit keeps retrying until it answers). Check: systemctl --user status litellm"
        systemctl --user reset-failed litellm &>/dev/null || true
        systemctl --user restart --no-block litellm &>/dev/null \
            || warn "Could not queue a litellm start — re-run setup.sh"
    }
    trap restore_litellm_service EXIT
    if [ -x "$LITELLM_BIN" ]; then
        # Converge-in-place (not skip): re-asserts the LITELLM_VERSION pin, so a
        # box sitting on anything else — a compromised 1.82.7/1.82.8, or a
        # version an older floor-based setup.sh floated onto — is moved to the
        # pinned one, and the --python pin is re-asserted against a distro
        # interpreter bump. A no-op when already converged.
        litellm_ver_before="$(litellm_tool_version)"
        log "LiteLLM present at $LITELLM_BIN (${litellm_ver_before:-unknown}) — converging to pinned ${LITELLM_VERSION} (python ${LITELLM_PYTHON_PIN})..."
        if uv tool install --upgrade --python "$LITELLM_PYTHON_PIN" "${LITELLM_UV_WITH[@]}" "$LITELLM_SPEC"; then
            # 19: assign litellm_ver_now directly — no second variable read
            # back through a `:-` fallback below.
            litellm_ver_now="$(litellm_tool_version)"
            if [ "$litellm_ver_before" != "$litellm_ver_now" ]; then
                log "LiteLLM ${litellm_ver_before:-?} -> ${litellm_ver_now:-?}"
            else
                log "LiteLLM already at ${litellm_ver_now:-$LITELLM_VERSION} (pinned)"
            fi
        else
            warn "LiteLLM install failed — keeping existing version"
        fi
    else
        log "Installing LiteLLM ${LITELLM_VERSION} via uv tool install (python ${LITELLM_PYTHON_PIN})..."
        # Non-fatal, same contract as the converge path above and as
        # LITELLM_CLIENT_BROKEN: a gateway that cannot be installed must not
        # abort the rest of the run (Claude Code, the managed-settings policy, an
        # overlay's remaining phases). An exact `==` pin makes this reachable in
        # a way the old `>=` floor was not: the user-level uv `exclude-newer`
        # cooldown shipped by the external hardening repo resolves the pin away
        # entirely for the first ~week after a LITELLM_VERSION bump, and a bare
        # `uv tool install` would then `set -e` the whole script dead. The
        # toolchain block below sees no venv prisma, raises LITELLM_CLIENT_BROKEN
        # itself, and Phase 7 leaves the unit stopped with the end-of-run banner.
        uv tool install --python "$LITELLM_PYTHON_PIN" "${LITELLM_UV_WITH[@]}" "$LITELLM_SPEC" \
            || error "LiteLLM ${LITELLM_VERSION} install failed — if this box has a uv cooldown (~/.config/uv/uv.toml exclude-newer), the pin may not have aged in yet. LiteLLM is left stopped; the rest of the run continues."
        # To enable optional LiteLLM features, add `extra_proxy` to the extras in
        # LITELLM_SPEC: RedisVL semantic caching, Google Cloud KMS + Azure Key
        # Vault as secret backends, and Resend for email — plus prisma, which
        # makes LITELLM_UV_WITH's --with prisma redundant.
    fi

    litellm_ver_now="${litellm_ver_now:-$(litellm_tool_version)}"
    # Both pins below are live constraints that would otherwise rot silently —
    # nag the moment the thing they were verified against is no longer newest.
    # The fastapi ceiling sits on a network-facing framework, so a stale one
    # also holds back its security releases.
    if version_newer_than "$litellm_ver_now" "$LITELLM_FASTAPI_GUARD_STALE_ABOVE"; then
        warn "litellm ${litellm_ver_now} > ${LITELLM_FASTAPI_GUARD_STALE_ABOVE}: check whether it contains upstream merge ecba48d (PR BerriAI/litellm#35773, issue #35763) — grep the wheel for get_flat_params, do NOT compare SHAs (see LITELLM_FASTAPI_GUARD). If present drop LITELLM_FASTAPI_GUARD, else bump LITELLM_FASTAPI_GUARD_STALE_ABOVE"
    fi
    # The Python pin exists because prisma-client-py 0.15.0 predates 3.14; a
    # newer release may well support it, at which point the pin can be dropped.
    prisma_py_ver="$(litellm_venv_pkg_version prisma)"
    if version_newer_than "$prisma_py_ver" "$LITELLM_PYTHON_PIN_STALE_ABOVE"; then
        warn "prisma-client-py ${prisma_py_ver} > ${LITELLM_PYTHON_PIN_STALE_ABOVE}: re-check whether LITELLM_PYTHON_PIN (${LITELLM_PYTHON_PIN}) is still needed — if it supports the distro default, drop the pin, else bump LITELLM_PYTHON_PIN_STALE_ABOVE"
    fi

    # The two toolchain files, deployed BEFORE anything reads the cache paths or
    # runs prisma — and UNCONDITIONALLY, outside the `prisma` binary check below:
    # the unit consumes prisma.env via `EnvironmentFile=-`, whose leading `-`
    # tolerates absence silently, so skipping the deploy on a box whose venv is
    # broken would drop the SERVICE to prisma-client-py's versioned cache tree —
    # the exact split CLAUDE.md > Troubleshooting ("any `prisma` command hangs")
    # documents, on the boxes least able to recover from it.
    #
    # prisma.env is the single source of every PRISMA_* switch for the
    # run_prisma wrapper below AND the unit, so what we warm is structurally
    # what the service reads; a change is a service change, so it feeds
    # LITELLM_CHANGED. pyproject.toml is prisma-client-py's per-cwd config (Node
    # LTS pin for the nodeenv). Both templates carry the per-switch rationale.
    #
    # render_template_if_changed, not a bare `sed | write_if_changed`: without
    # pipefail a failed render installs a 0-byte file, and an empty
    # PRISMA_BINARY_CACHE_DIR read back from it then makes PRISMA_NPM_ENTRIES
    # root-relative, turning the heal below into `rm -rf /node_modules …`.
    if render_template_if_changed "$SCRIPT_DIR/configs/litellm-prisma.env" \
        "$LITELLM_PRISMA_ENV_FILE" "prisma.env" \
        -e "s|__HOME__|${HOME}|g"; then
        log "Prisma toolchain switches updated"
    fi
    deploy_config "$SCRIPT_DIR/configs/litellm-pyproject.toml" "$LITELLM_PYPROJECT_FILE"

    # Generate the Prisma client + fetch engine binaries. Upstream's Dockerfiles
    # do `prisma generate --schema=./schema.prisma` as a build step right after
    # pip install; `uv tool install` doesn't, so without this the proxy crashes
    # on first DB connect with "The Client hasn't been generated yet".
    # One predicate for "the toolchain work below can run": the venv's prisma
    # exists AND prisma.env yields a usable cache dir. Resolving it in a
    # function keeps PRISMA_BINARY_CACHE_DIR from having to double as a
    # pass/fail channel between two tests of the same condition. The
    # absolute-path assertion matters because the value reaches `rm -rf` in the
    # heals below — a hand-broken prisma.env must not aim them at /.
    # Both failure paths raise LITELLM_CLIENT_BROKEN, deliberately: whatever
    # stopped the toolchain also stopped `prisma generate`, so the venv's
    # generated client is stale-or-absent and a start would crash-loop on
    # "The Client hasn't been generated yet" (20x, then start-limit parked) with
    # nothing in the run's output pointing at the cause. Silence here was the
    # worse failure: the missing-CLI branch used to `return 1` with no message
    # at all, so a converge run whose `uv tool install --upgrade` failed (warned,
    # non-fatal) skipped the whole block invisibly and Phase 7 started the proxy
    # anyway. `bin/prisma` is prisma-client-py's own console script, so its
    # absence means the package — and therefore the client — is gone too.
    prisma_toolchain_usable() {
        if [ ! -x "${UV_LITELLM_VENV}/bin/prisma" ]; then
            error "No prisma CLI at ${UV_LITELLM_VENV}/bin/prisma — the LiteLLM venv is incomplete (see any install warning above); Prisma client not generated and LiteLLM is left stopped (see the banner at the end)."
            LITELLM_CLIENT_BROKEN=1
            LITELLM_CLIENT_BROKEN_WHY=install
            return 1
        fi
        PRISMA_BINARY_CACHE_DIR="$(read_env_file_var "$LITELLM_PRISMA_ENV_FILE" PRISMA_BINARY_CACHE_DIR)"
        [[ "$PRISMA_BINARY_CACHE_DIR" == /* ]] && return 0
        error "PRISMA_BINARY_CACHE_DIR in ${LITELLM_PRISMA_ENV_FILE} is not an absolute path — refusing to touch the Prisma caches; LiteLLM is left stopped (see the banner at the end)."
        LITELLM_CLIENT_BROKEN=1
        LITELLM_CLIENT_BROKEN_WHY=toolchain
        return 1
    }
    if prisma_toolchain_usable; then
        # --- Toolchain heal + warm-up: runs on EVERY pass, deliberately outside
        # the generate gate below — a no-version-change run skips generate, and
        # that was exactly the run on which a wedged box needed repair. The
        # service's own bare `prisma` spawn (proxy_cli.py, untimed) re-installs
        # the CLI whenever these caches are incomplete, so they must be complete
        # BEFORE the unit starts. Mechanism + the two cache paths: CLAUDE.md >
        # Troubleshooting, "any `prisma` command hangs".
        PRISMA_NODEENV_DIR="${HOME}/.cache/prisma-python/nodeenv"
        # The npm-owned entries in the (shared) binaries dir — one definition
        # for both rm sites below, same rule as LITELLM_UV_WITH: a drifted pair
        # that removes node_modules but leaves package.json is a state npm
        # treats as satisfied. The engine copies live INSIDE node_modules
        # (@prisma/engines/) and go with it — that is fine: the CLI restores
        # them from ~/.cache/prisma/master/<hash>/ without touching the
        # network (verified), and that tree is never removed here.
        PRISMA_NPM_ENTRIES=(
            "${PRISMA_BINARY_CACHE_DIR}/node_modules"
            "${PRISMA_BINARY_CACHE_DIR}/package.json"
            "${PRISMA_BINARY_CACHE_DIR}/package-lock.json"
        )
        # Every prisma call goes through this wrapper so no call site can
        # silently drop a guard (claude_mutate's rule): the prisma.env switches
        # (sourced, not restated); the cwd (the pyproject above); the generator
        # PATH (prisma's Node CLI shells out to `prisma-client-py` in the
        # venv); stdin from /dev/null (nothing in the toolchain may wait on a
        # terminal — the bun-REPL stall would have been an instant fall-through
        # with this alone); and the per-step budget (prisma.env's
        # LITELLM_PRISMA_BOOTSTRAP_TIMEOUT, upstream 0.4.84's own; `-k` is
        # required, not decoration — plain `timeout` sends only SIGTERM then
        # waits, and this child is a Node CLI; timeout signals its whole
        # process group, so npm/node grandchildren die with it).
        # Network note: `--version` and `generate` fetch a missing engine from
        # binaries.prisma.sh (the npm postinstall that would otherwise fetch
        # it is disabled on overlays with ignore-scripts=true) into
        # ~/.cache/prisma/master/<hash>/<target>/ and copy it into
        # node_modules/@prisma/engines/; with the cache populated neither
        # touches the network, which is why rm-ing the npm entries is safe.
        # Digits-only, not just non-empty: a stray \r or space from a hand-edited
        # prisma.env would reach `timeout` as an invalid interval and fail every
        # call below with a message that names neither this file nor the cause.
        PRISMA_STEP_TIMEOUT="$(read_env_file_var "$LITELLM_PRISMA_ENV_FILE" LITELLM_PRISMA_BOOTSTRAP_TIMEOUT)"
        [[ "$PRISMA_STEP_TIMEOUT" =~ ^[0-9]+$ ]] || PRISMA_STEP_TIMEOUT=600
        run_prisma() {
            (
                # A failed `.` does NOT stop the subshell (set -e is suppressed —
                # every call site is an `if` condition), so without this guard
                # prisma would run with none of the switches: no
                # PRISMA_USE_GLOBAL_NODE=false, no flat cache dir, no
                # CHECKPOINT_DISABLE. Fail the call instead of silently warming a
                # different tree than the service reads.
                # The `||` MUST hang off the `.` itself, never off a
                # `{ set -a; . file; set +a; }` group: a group's status is its
                # LAST command's, so `set +a` (always 0) would swallow the
                # failure and the guard would never fire.
                set -a
                # shellcheck source=/dev/null
                . "$LITELLM_PRISMA_ENV_FILE" \
                    || { set +a; warn "Could not source ${LITELLM_PRISMA_ENV_FILE} — refusing to run prisma without its switches"; exit 1; }
                set +a
                cd "$LITELLM_CONFIG_DIR" \
                && PATH="${UV_LITELLM_VENV}/bin:$PATH" \
                    timeout -k 15 "$PRISMA_STEP_TIMEOUT" "${UV_LITELLM_VENV}/bin/prisma" "$@" </dev/null
            )
        }
        # Heal 1 — the private Node runtime: prisma-client-py installs it only
        # when this dir is ABSENT. Do NOT reduce the probe to a `-d` test — the
        # directory existing without bin/node is the broken state it would then
        # skip forever.
        if [ -d "$PRISMA_NODEENV_DIR" ] && [ ! -x "${PRISMA_NODEENV_DIR}/bin/node" ]; then
            warn "Prisma Node toolchain at ${PRISMA_NODEENV_DIR} has no bin/node (interrupted install) — removing so it reinstalls"
            rm -rf "$PRISMA_NODEENV_DIR"
        fi
        # Heal 2 — the npm-installed Prisma CLI. The wrapper does reinstall on
        # a missing entrypoint, but npm no-ops against a surviving
        # node_modules/prisma/package.json (it never verifies file
        # completeness), so a half-extracted tree is never repaired in-place —
        # rm the npm entries so the install runs clean.
        if [ -d "${PRISMA_BINARY_CACHE_DIR}/node_modules" ] \
            && [ ! -f "${PRISMA_BINARY_CACHE_DIR}/node_modules/prisma/build/index.js" ]; then
            warn "Prisma CLI cache at ${PRISMA_BINARY_CACHE_DIR} has node_modules but no CLI entrypoint (interrupted npm install) — removing the npm entries so they reinstall"
            rm -rf "${PRISMA_NPM_ENTRIES[@]}"
        fi
        # Warm-up: one bounded `prisma --version` (upstream 0.4.84's own
        # ensure_prisma_toolchain shape) so the nodeenv + CLI installs happen
        # HERE, supervised and time-boxed, never inside the service. ~1s on a
        # warm box. Non-fatal on failure, but DO drop both caches first —
        # unlike generate (which also fails on schema/generator/venv problems),
        # a warm-box --version exercises only node + the CLI entrypoint, so its
        # failure IS evidence the caches are bad, including the one shape the
        # heals can't see: files present and executable but broken. The next
        # run (or the generate below, on fresh installs) retries from clean.
        prisma_warmup_started=$SECONDS
        if run_prisma --version >/dev/null; then
            log "Prisma toolchain ready ($((SECONDS - prisma_warmup_started))s)"
        else
            rm -rf "$PRISMA_NODEENV_DIR" "${PRISMA_NPM_ENTRIES[@]}"
            warn "Prisma toolchain warm-up failed or timed out (${PRISMA_STEP_TIMEOUT}s) — removed the caches; the next run retries from clean"
        fi

        # The generated client is regenerated whenever its PROVENANCE no longer
        # matches the installed reality. The stamp records what it was
        # generated from — the exact field list is prisma_stamp_for's
        # docstring, which is the authority; do not restate it here.
        #
        # A version-change flag plus an import probe is NOT enough, and the field
        # proved it. `uv tool install` leaves an unchanged `prisma` package (and
        # its in-place generated client.py) untouched across a litellm upgrade,
        # so a run that upgrades litellm and then dies before generate completes
        # leaves a client built from the PREVIOUS schema. The next run sees no
        # version change and a client that imports perfectly, and skips
        # regeneration — forever. The proxy then starts, serves /ui, and fails
        # only where the schemas differ (`FieldNotFoundError`, `'Batch' object
        # has no attribute …`). Hashing the schema catches exactly that; the
        # generator and interpreter fields catch a prisma-client-py upgrade or a
        # distro Python bump against an unchanged schema.
        #
        # The import probe is kept as an ADDITIONAL trigger: it still catches a
        # generate interrupted mid-write, which leaves a client.py that exists
        # (and could stamp-match) but cannot import. `from prisma import Prisma`
        # is the exact import the proxy performs at startup, so it passes iff
        # the proxy would.
        #
        # A glob, not `import litellm.proxy`: importing litellm to build a path
        # pays the full proxy import (~10-17s cold on one core) plus its
        # module-level cost-map fetch. `|| true`: a miss must fall through to
        # the diagnostic below, not abort under `set -e`.
        LITELLM_SCHEMA="$(compgen -G "${UV_LITELLM_VENV}/lib/python*/site-packages/litellm/proxy/schema.prisma" | head -1 || true)"
        # Stamp computed from the SAME schema path the generate below uses, so
        # stamp and client can never disagree about what produced what; empty
        # when the schema is unreadable, which the elif then treats as stale.
        prisma_stamp_file="${UV_LITELLM_VENV}/.litellm-prisma-stamp"
        prisma_stamp_want="$(prisma_stamp_for "$LITELLM_SCHEMA" "$litellm_ver_now" "$prisma_py_ver" || true)"
        if [ -z "$LITELLM_SCHEMA" ] || [ ! -f "$LITELLM_SCHEMA" ]; then
            error "Could not locate litellm's schema.prisma — Prisma client not generated; LiteLLM is left stopped (see the banner at the end)."
            LITELLM_CLIENT_BROKEN=1
            LITELLM_CLIENT_BROKEN_WHY=toolchain
        elif [ -n "$prisma_stamp_want" ] \
            && [ "$(cat "$prisma_stamp_file" 2>/dev/null || true)" = "$prisma_stamp_want" ] \
            && litellm_venv_python -c 'from prisma import Prisma' &>/dev/null; then
            log "Prisma client matches litellm ${litellm_ver_now:-?} — skipping generate"
        else
            # On a cold box this downloads query engines for ALL FIVE
            # binaryTargets litellm's schema lists for its Docker images
            # (~75MB compressed → ~138MB on disk, single-core gunzip+sha256)
            # even though this box can only execute the computed one. Verified
            # unavoidable at prisma 5.17 — PRISMA_CLI_BINARY_TARGETS looks
            # like the lever but is read only by @prisma/engines' npm
            # postinstall (ensureBinariesExist), never by generate's
            # per-schema downloads (tested cold, 2026-08-20: the env var
            # delivered, 138MB still fetched) — do not re-try it. One-time per
            # engine hash: ~/.cache/prisma + the node_modules copies persist
            # across litellm upgrades, and the heals above never remove them.
            log "Generating Prisma client (a cold box downloads ~75MB of engine binaries here)..."
            # Toolchain already healed + warmed above. No cache cleanup on
            # failure — generate also fails on schema/generator/venv problems
            # that are no evidence of a bad cache, and rm-ing would throw away
            # a complete multi-minute Node install (the warm-up's failure
            # branch owns the bad-cache case). Non-fatal: LITELLM_CLIENT_BROKEN
            # keeps the unit stopped and the rest of the run proceeds.
            prisma_generate_started=$SECONDS
            if run_prisma generate --schema="$LITELLM_SCHEMA"; then
                # Stamp only on success — a stamp written ahead of the
                # generate would re-create the sticky-stale state it exists to
                # prevent. It sits at the venv root, which uv may keep across an
                # in-place rebuild; the interpreter and generator fields in
                # prisma_stamp_for are what cover that case.
                printf '%s\n' "$prisma_stamp_want" > "$prisma_stamp_file"
                log "Prisma client generated ($((SECONDS - prisma_generate_started))s)"
            else
                rm -f "$prisma_stamp_file"
                error "prisma generate failed or timed out (${PRISMA_STEP_TIMEOUT}s) — Prisma client not generated; LiteLLM is left stopped (see the banner at the end). The next run re-heals an incomplete toolchain and regenerates."
                LITELLM_CLIENT_BROKEN=1
                LITELLM_CLIENT_BROKEN_WHY=generate
            fi
        fi
    fi

    # Close the window opened at the top of 4a: release the hold only. The
    # start is ALWAYS
    # deferred to Phase 7 — the run's single litellm start, sequenced after
    # Phase 6's pg_isready gate (a restored VM snapshot's cluster is down until
    # Phase 6 starts it) and against the freshly deployed unit/env/config. A
    # start here cost the arc twice whenever Phase 7 then restarted (upgrade,
    # env/config/unit change — e.g. every box's first run after a template
    # edit): Phase 7 cgroup-killed the still-converging 4a start and re-ran
    # bare `prisma` + the schema sync + the cold proxy import, minutes on a
    # CPU-starved VM (observed 2026-08-20). Accepted cost: the proxy is down
    # across phases 4b-6 (nobody is using it — Phase 0 exits while `claude`
    # runs) and a no-op run no longer overlaps the arc with 4b-6. The EXIT trap
    # stays armed as the abort belt for 4b-6; Phase 7 disarms it after its
    # start.
    release_user_service_starts litellm
    log "LiteLLM start deferred to Phase 7 (single start per run, after the Postgres gate)"
fi

# 4b. Claude Code (official installer; upgrade in place when present; all modes)
if have_claude; then
    # Upgrade-in-place (not skip): `claude update` is a no-op when already latest
    # and still works under DISABLE_AUTOUPDATER=1 (that gates only the background
    # check, not the explicit command; DISABLE_UPDATES is not set). Resolve the
    # real binary; claude may live outside ~/.local/bin (e.g. a host-provided symlink).
    claude_bin="$(command -v claude 2>/dev/null || echo "${HOME}/.local/bin/claude")"
    log "Claude Code present — running 'claude update'..."
    # Same two hazards Phase 8e's claude_mutate guards against, and the same
    # fixes — `claude` is a Node TUI that emits terminal-capability queries
    # (OSC 11, DA1) AFTER finishing its work and blocks forever waiting for
    # replies whenever stdout is a tty and stdin cannot answer. An overlay
    # updater that runs setup.sh with stdin </dev/null but stdout still on the
    # terminal hits exactly that, and this call had no bound at all.
    # `| cat` (not a $(...) capture) detaches stdout from the tty — which is
    # what stops the probe — while still streaming the ~300MB download's
    # progress, so a slow update doesn't look hung. The pipeline's own status
    # is cat's, hence PIPESTATUS; read it on the next line, before any other
    # command clobbers it.
    timeout -k 15 600 "$claude_bin" update </dev/null 2>&1 | cat
    claude_update_rc=${PIPESTATUS[0]}
    [ "$claude_update_rc" -eq 0 ] \
        || warn "claude update failed or timed out (rc=${claude_update_rc}) — keeping existing version"
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

# Keep only the active binary in ~/.local/share/claude/versions. Claude Code's
# own sweep bottoms out at three ~300 MB versions (see prune_claude_versions in
# common.sh); this reclaims the other two. Also the one place that notices when
# the launcher stopped being a symlink, which silently disables both that sweep
# and future updates.
prune_claude_versions || warn "Claude Code version prune failed — continuing"

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
#
# Third fallback, local-LiteLLM modes only: the deployed EnvironmentFile. Phase
# 5b already treats that file as a persistent home for provider secrets — it
# carries forward any the collector didn't find — so a box whose .env was
# deleted after a successful install KEEPS serving azure/gpt-5.6-* while Phase
# 5a used to see no Azure credentials at all. The visible symptom of that
# asymmetry was the CLAUDE_CODE_MAX_CONTEXT_TOKENS scrub below firing on a box
# whose models still take 1.05M input: Claude Code silently dropped back to
# believing 200K and auto-compacted five times too early. Scoped to
# WITH_LOCAL_LITELLM because only there is this file the credentials the
# gateway will actually run with — under --harden-only it may be a leftover
# from an earlier full install, pointing at models the REMOTE router may not
# serve.
_azure_env_file=""
[ "$WITH_LOCAL_LITELLM" = "true" ] && _azure_env_file="$LITELLM_ENV_FILE"
_azure_endpoint_raw="${AZURE_RESOURCE_ENDPOINT:-$(read_profile_export "AZURE_RESOURCE_ENDPOINT")}"
if [ -z "$_azure_endpoint_raw" ] && [ -n "$_azure_env_file" ]; then
    _azure_endpoint_raw="$(read_env_file_var "$_azure_env_file" AZURE_RESOURCE_ENDPOINT)"
fi
if [ -n "$_azure_endpoint_raw" ]; then
    AZURE_RESOURCE_ENDPOINT="$(normalize_azure_v1_endpoint "$_azure_endpoint_raw")"
    export AZURE_RESOURCE_ENDPOINT
fi
unset _azure_endpoint_raw

# Same ~/.profile fallback for the key half of the pair. Without it the two
# halves resolve from different sources: with Azure creds exported only in
# ~/.profile (a supported discovery location — Phase 5b's collector reads it)
# and setup run from a shell that never sourced it, the endpoint resolves and
# the key doesn't, so the gateway gets working credentials while the Phase 5a
# gate below writes all four model selectors EMPTY and fires the misleading
# "no Azure credentials" banner.
if [ -z "${AZURE_OPENAI_API_KEY:-}" ]; then
    _azure_key_raw="$(read_profile_export "AZURE_OPENAI_API_KEY")"
    if [ -z "$_azure_key_raw" ] && [ -n "$_azure_env_file" ]; then
        _azure_key_raw="$(read_env_file_var "$_azure_env_file" AZURE_OPENAI_API_KEY)"
    fi
    if [ -n "$_azure_key_raw" ]; then
        AZURE_OPENAI_API_KEY="$_azure_key_raw"
        export AZURE_OPENAI_API_KEY
    fi
    unset _azure_key_raw
fi
unset _azure_env_file

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
update_profile_export "DOTNET_CLI_TELEMETRY_OPTOUT"   "1"
update_profile_export "POWERSHELL_TELEMETRY_OPTOUT"   "1"
update_profile_export "AZURE_CORE_COLLECT_TELEMETRY"  "0"
update_profile_export "HF_HUB_DISABLE_TELEMETRY"      "1"
update_profile_export "SCARF_ANALYTICS"               "false"

# Write or scrub one Claude Code toggle. Under --no-profile-toggles (overlays
# like ct-dfir-llm/ct-kali-llm, whose own setup deploys
# /etc/claude-code/managed-settings.json carrying these in its env: block) the
# profile mirror is redundant, so nothing is written and previously-written
# toggles are scrubbed — already-deployed boxes self-heal on their next run.
profile_toggle() {
    if [ "$PROFILE_TOGGLES" = "true" ]; then
        update_profile_export "$1" "$2"
    else
        remove_profile_export "$1"
    fi
}

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
# gated GrowthBook fetches (#45918); the env: block's DISABLE_GROWTHBOOK
# (mirrored below) still covers that.
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
# (repo-owned — fail loudly, not with silently-missing toggles). The jq
# extraction runs under --no-profile-toggles too: its key list is the scrub
# list for the current block (a key retired upstream still needs the explicit
# retired-exports scrub below, same as the write path).
managed_env_toggles="$(jq -r '.env | to_entries[] | "\(.key)=\(.value)"' "$SCRIPT_DIR/configs/claude-managed-settings.json")"
if [ -z "$managed_env_toggles" ]; then
    error "No env toggles found in claude-managed-settings.json — refusing to continue with an empty policy env block"
    exit 1
fi
while IFS='=' read -r toggle_var toggle_val; do
    profile_toggle "$toggle_var" "$toggle_val"
done <<< "$managed_env_toggles"

# UX/behavior preferences — ~/.profile prefs the user can `unset`, not
# enforced policy; a --no-profile-toggles overlay instead carries them in its
# managed env: block, where they ARE enforced (overlay's deliberate choice).
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
profile_toggle "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"          "75"
profile_toggle "CLAUDE_CODE_FORK_SUBAGENT"               "1"

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
# VSCODE_TELEMETRY_DISABLE / VSCODE_CRASH_REPORTER_DISABLE: community folklore
# (a Windows-telemetry gist) — nothing in VS Code reads them. The real control
# is the telemetry.telemetryLevel setting / enterprise TelemetryLevel policy
# (vscode-setup's domain, not an env var).
remove_profile_export "VSCODE_TELEMETRY_DISABLE"
remove_profile_export "VSCODE_CRASH_REPORTER_DISABLE"

# Default model selectors + gateway discovery + effort. In ~/.profile (not
# managed-settings) so they apply in --router-only too. Four selectors:
# haiku/sonnet/opus plus fable, the 4th tier (CC >=2.1.170). Values are the
# upstream provider-prefixed ids surfaced by litellm-config.yaml when Azure
# creds are supplied. When the user leaves Azure blank in .env, write empty
# values (unless a prior re-run / manual edit already set them) and emit a
# banner at end-of-script telling the user to add a model via /ui and fill
# these in.
# No *_SUPPORTED_CAPABILITIES (scrubbed above) or _NAME/_DESCRIPTION
# companions; the full thinking/effort story is in CLAUDE.md > "Model naming".
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
        # fable -> sol; 404s without a gpt-5.6-sol deployment (CLAUDE.md > "Model naming")
        update_profile_export "ANTHROPIC_DEFAULT_FABLE_MODEL"  "azure/gpt-5.6-sol"
        # Believed context window: CC assumes 200K for unrecognized gateway
        # ids and no documented knob raises it (anthropics/claude-code#68522).
        # This undocumented pair does (issue-thread workaround, deploy-verified
        # 2026-07-30; third-party gateway docs use the same mechanism).
        # Session-global, so written only on this Azure path where every
        # served tier takes 1.05M input; a /ui-added smaller-window model
        # would be over-believed -> API 400s before compaction fires. See
        # CLAUDE.md > "Model naming".
        update_profile_export "CLAUDE_CODE_MAX_CONTEXT_TOKENS" "1000000"
        update_profile_export "CLAUDE_CODE_DISABLE_1M_CONTEXT" "0"
    else
        for var in ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL; do
            existing="$(read_profile_export "$var")"
            if [ -z "$existing" ]; then
                update_profile_export "$var" ""
                NEEDS_MODEL_CONFIG=1
            fi
        done
        # Box flipped Azure -> no-Azure (creds removed, /ui model instead):
        # drop the 1M belief written by the branch above, or CC keeps assuming
        # a 1.05M window for a possibly-200K /ui model -> API 400s before
        # auto-compact fires. Value-scoped so a manual window (CLAUDE.md tells
        # no-Azure users to set their model's real limit) is preserved.
        if [ "$(read_profile_export "CLAUDE_CODE_MAX_CONTEXT_TOKENS")" = "1000000" ]; then
            remove_profile_export "CLAUDE_CODE_MAX_CONTEXT_TOKENS"
            remove_profile_export "CLAUDE_CODE_DISABLE_1M_CONTEXT"
        fi
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
    # A stale forced 1M belief is dangerous against the real Anthropic API
    # (Claude windows are known natively; a 200K-plan session would overrun).
    remove_profile_export "CLAUDE_CODE_MAX_CONTEXT_TOKENS"
    remove_profile_export "CLAUDE_CODE_DISABLE_1M_CONTEXT"
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

# A shell-exported ANTHROPIC_API_KEY silently outranks ANTHROPIC_AUTH_TOKEN
# in Claude Code → 401 at the gateway (CLAUDE.md > "Master-key strategy").
# Warn-only: blanking or scrubbing the export would destroy the user's
# collector source (~/.profile is a supported key-discovery location for
# Phase 5b). Checked against the files, not $ANTHROPIC_API_KEY — .env is
# sourced with set -a above, so an env test would false-positive on the
# supported .env path (scoped to this script's process only). Skipped when
# no gateway is wired (--install-only): direct-Anthropic boxes may
# legitimately export the key. Explicitly blanked exports (="", ='', =) are
# harmless — CC only honors non-empty values.
# Covers every startup file a login/interactive shell reads, not just
# ~/.profile: ~/.bash_profile is read FIRST by bash login shells (this repo
# installs a shim there, and installers append to it), and zsh reads
# ~/.zshenv/~/.zprofile before ~/.zshrc — a key exported in any of them wins
# at runtime. Leading whitespace is tolerated so an indented export is caught.
WARN_STRAY_ANTHROPIC_KEY=0
if [ "$WITH_GATEWAY" = "true" ] \
    && grep -hsE '^[[:space:]]*export[[:space:]]+ANTHROPIC_API_KEY=' \
        "$PROFILE_FILE" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.bashrc" \
        "$HOME/.zshenv" "$HOME/.zprofile" "$HOME/.zshrc" \
        | grep -qvxE "[[:space:]]*export[[:space:]]+ANTHROPIC_API_KEY=(\"\"|''|)"; then
    WARN_STRAY_ANTHROPIC_KEY=1
    warn "ANTHROPIC_API_KEY is exported in a shell profile — Claude Code will prefer it over the gateway token (details in the end-of-setup banner)"
fi

# 5b. Provider secrets → in-memory env content. Auto-discovers every
# LiteLLM-relevant provider env var from current shell + ~/.profile + .env
# (sourced above). Skipped in harden-only / install-only (no local LiteLLM).
if [ "$WITH_LOCAL_LITELLM" = "true" ]; then
    LITELLM_ENV_CONTENT="LITELLM_MASTER_KEY=${ANTHROPIC_AUTH_TOKEN}"$'\n'
    LITELLM_ENV_CONTENT+="$(collect_litellm_provider_vars)"$'\n'
    # Carry forward provider secrets the collector did NOT find, from the env
    # file the service is currently running with. The deployed file is their
    # only persistent home — the collector reads just the current shell,
    # ~/.profile and .env, and Phase 5a deliberately never writes provider
    # secrets to ~/.profile — so without this a run with .env missing or its
    # values blank (the shape .env.example ships) silently erases
    # AZURE_OPENAI_API_KEY and friends. The proxy still boots and /ui still
    # logs in, and every model call fails.
    #
    # Fallback only, never an override: a key the collector produced is left
    # exactly as collected, so a fresh value in .env still wins over a stale one
    # on disk. Same rule, and same reason, as the UI_* carry-over in Phase 6.
    # Restricted to names the collector itself recognises, so the file cannot
    # accumulate unrelated keys across runs.
    #
    # `tac`: LAST-wins on a duplicated key — same rule, same reason as
    # read_env_file_var (common.sh). Without it the loop's already-present guard
    # makes the carry-over first-wins and resurrects the stale value.
    if [ -f "$LITELLM_ENV_FILE" ]; then
        while IFS= read -r _carry_line; do
            _carry_name="${_carry_line%%=*}"
            is_litellm_provider_var "$_carry_name" || continue
            # Leading newline on the haystack so the first line matches the same
            # way every other one does.
            [[ $'\n'"$LITELLM_ENV_CONTENT" == *$'\n'"${_carry_name}="* ]] && continue
            LITELLM_ENV_CONTENT+="${_carry_line}"$'\n'
            warn "${_carry_name} was not found in .env / the shell / ~/.profile — carried it over from ${LITELLM_ENV_FILE} so model calls keep working. Restore it in .env to keep this run reproducible."
        done < <(grep -E '^[A-Z][A-Z0-9_]*=' "$LITELLM_ENV_FILE" 2>/dev/null | tac || true)
    fi
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
# Phase 4a contributes no signal of its own: in native mode it stops the unit
# unconditionally and never restarts it, so Phase 7's restart_user_service_if_stale
# fires on its `! is-active` leg regardless; under --docker, Phase 4a is skipped
# entirely. What matters here is the env/config/unit/compose writes below, which
# is what makes a docker no-op re-run cheap.
LITELLM_CHANGED=0
if [ "$WITH_LOCAL_LITELLM" = "true" ]; then
    log "=== Phase 6: Postgres ==="

    # Preserve the auto-generated DB password and any manual UI_USERNAME /
    # UI_PASSWORD overrides (.env.example documents setting those by hand)
    # across reruns — this phase regenerates the env file wholesale below, and
    # the provider-var collector deliberately excludes UI_*. Selective greps
    # rather than `source $LITELLM_ENV_FILE` because the latter would let stale
    # provider secrets in the env file shadow fresh values from .env.
    PERSISTED_DB_PASSWORD=""
    PERSISTED_SALT_KEY=""
    PERSISTED_MASTER_KEY=""
    PERSISTED_UI_LINES=""
    if [ -f "$LITELLM_ENV_FILE" ]; then
        PERSISTED_DB_PASSWORD="$(read_env_file_var "$LITELLM_ENV_FILE" LITELLM_DB_PASSWORD)"
        PERSISTED_SALT_KEY="$(read_env_file_var "$LITELLM_ENV_FILE" LITELLM_SALT_KEY)"
        # The master key the DEPLOYED service last ran with — the key that
        # actually encrypted any /ui-stored credentials under litellm's
        # salt-key fallback. Seeds the first LITELLM_SALT_KEY write below, so
        # a run that ALSO rotates the master key (new sk- value in .env) can't
        # pin the salt to a key those rows were never encrypted with.
        PERSISTED_MASTER_KEY="$(read_env_file_var "$LITELLM_ENV_FILE" LITELLM_MASTER_KEY)"
        PERSISTED_UI_LINES="$(grep -E '^UI_(USERNAME|PASSWORD)=' "$LITELLM_ENV_FILE" 2>/dev/null || true)"
    fi

    # The exclusion globs must match ONLY the URLs this phase generates below
    # (role, host, and dbname all pinned), not any loopback URL with the
    # `litellm` role: a user-supplied `…@127.0.0.1:5433/mydb` (pgbouncer / SSH
    # tunnel to a remote Postgres) is external, and a broader glob would
    # silently discard it and provision a local DB instead. The TCP glob is
    # port-wildcarded because the fallback below is port-corrected
    # (`:${pg_port}` on a drifted cluster) — the dbname pin keeps tunnel URLs
    # to other databases external. The socket globs require `:` or `/`
    # immediately after `localhost` (hosts merely prefixed with "localhost"
    # stay external) and the exact query tail; the portless form is the URL
    # shape older installs wrote.
    if [ -n "${DATABASE_URL:-}" ] \
       && [[ "${DATABASE_URL}" != postgresql://litellm:*@127.0.0.1:*/litellm ]] \
       && [[ "${DATABASE_URL}" != postgresql://litellm:*@localhost:*/litellm\?host=/run/postgresql ]] \
       && [[ "${DATABASE_URL}" != postgresql://litellm:*@localhost/litellm\?host=/run/postgresql ]]; then
        log "DATABASE_URL set externally — skipping local Postgres install"
        LITELLM_DB_URL="$DATABASE_URL"
    else
        if ! command -v psql &>/dev/null; then
            log "Installing postgresql via apt..."
            apt_install postgresql
        fi
        # Pick the cluster to enable at boot. With several clusters, pg_wrapper
        # sends the bootstrap below (`sudo -u postgres psql`) to the one on port
        # 5432 — postgresql-common's own rule ("the one listening on the default
        # port 5432") — and the runtime DATABASE_URL follows the bootstrap via
        # SHOW port, so anchoring the enable here keeps all three on the same
        # cluster. (Single cluster: pg_wrapper uses it whatever its port, and
        # SHOW port follows.) Anchor on the port, not "the first cluster": pg_lsclusters
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
        pg_isready -q || { error "Postgres not accepting connections after 30s"; exit 1; }

        LITELLM_DB_PASSWORD="${PERSISTED_DB_PASSWORD:-$(openssl rand -hex 24)}"
        [ -z "$PERSISTED_DB_PASSWORD" ] && log "Generated new LITELLM_DB_PASSWORD"

        # Capture psql output to a variable so `set -e` catches psql failures
        # (a `psql | grep -q` pipe would mask them — grep's exit, not psql's).
        # One query answers both "does the role exist" and "is its stored
        # verifier scram": empty → no role; f → md5/NULL verifier, which the
        # scram-sha-256 pg_hba rule the socket URL relies on can never match
        # (pre-PG14 `password_encryption = md5` boxes; coalesce turns SQL
        # NULL into f so a passwordless role isn't mistaken for a missing
        # one); t → fine. pg_authid needs superuser — we are one here.
        role_scram=$(sudo -u postgres psql -tAc \
            "SELECT coalesce(rolpassword LIKE 'SCRAM-SHA-256%', false) FROM pg_authid WHERE rolname='litellm'")
        if [ -n "$role_scram" ]; then
            # One path owns "the role's password is right": sync it when it
            # changed, or re-hash the same value in place when the verifier
            # predates the scram default — skip the SQL round-trip only when
            # both hold (the no-op rerun). SET is session-scoped; both
            # statements ride one psql invocation, fed via stdin so the
            # password stays out of world-readable argv (/proc/*/cmdline —
            # same rule as pg_url_works). ON_ERROR_STOP keeps a SQL failure
            # fatal for `set -e` (stdin scripts otherwise exit 0); the
            # pipeline's status is psql's, so `set -e` still sees it.
            if [ "$LITELLM_DB_PASSWORD" != "$PERSISTED_DB_PASSWORD" ] || [ "$role_scram" != "t" ]; then
                printf '%s\n' "SET password_encryption='scram-sha-256'; ALTER ROLE litellm WITH LOGIN PASSWORD '${LITELLM_DB_PASSWORD}'" \
                    | sudo -u postgres psql -q -v ON_ERROR_STOP=1 -f - >/dev/null
                log "Synced Postgres role 'litellm' password (scram-sha-256)"
            fi
        else
            printf '%s\n' "SET password_encryption='scram-sha-256'; CREATE ROLE litellm WITH LOGIN PASSWORD '${LITELLM_DB_PASSWORD}'" \
                | sudo -u postgres psql -q -v ON_ERROR_STOP=1 -f - >/dev/null
            log "Created Postgres role 'litellm'"
        fi

        db_exists=$(sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='litellm'")
        if [ "$db_exists" != "1" ]; then
            sudo -u postgres createdb -O litellm litellm
            log "Created Postgres database 'litellm'"
        fi

        # Same host DB in both modes, same transport too: the *Unix socket*
        # (native since the socket switch; --docker via the bind-mounted socket
        # dir — see CLAUDE.md "Docker mode"). The socket sidesteps the contested
        # TCP namespace: a container publishing 5432 (docker-proxy) can capture
        # the TCP URL's backend but cannot touch /run/postgresql/.s.PGSQL.<port>
        # — the incident this guards against.
        #
        # Port of the cluster the bootstrap above hit (same pg_wrapper routing
        # — see the cluster-enable note higher up); it also names the socket
        # file (.s.PGSQL.<port>), so a cluster that drifted to 5433 gets a URL
        # that still reaches it. The psql calls above succeeding makes an empty
        # read here anomalous; defaulting to 5432 is the pre-derivation
        # behavior — degradation, not breakage.
        pg_port="$(pg_setting port)"
        pg_port="${pg_port:-5432}"

        # Preflight the socket URL and only then commit it, falling back so no
        # existing install can be broken by the switch — a hand-edited pg_hba
        # or otherwise failed socket auth costs a warning, not the proxy. The
        # port rides the URL *authority* (@localhost:PORT/), which libpq and
        # Prisma both parse; a &port= query param is only libpq-verified. The
        # probe URL carries no password (see pg_url_works). On a first-probe
        # failure, force the postmaster to re-read pg_hba (pg_reload_conf —
        # works regardless of the umbrella unit's state, unlike `systemctl
        # reload`) and retry once: that covers both a freshly inserted rule
        # racing its async SIGHUP and a rule a previous run left on disk whose
        # reload never landed — the shape ensure_pg_socket_scram_rule's
        # file-presence idempotence check cannot see.
        ensure_pg_socket_scram_rule
        socket_tail="localhost:${pg_port}/litellm?host=/run/postgresql"
        probe_url="postgresql://litellm@${socket_tail}"
        if pg_url_works "$probe_url" "$LITELLM_DB_PASSWORD" \
           || { sudo -u postgres psql -qAtc 'SELECT pg_reload_conf()' >/dev/null 2>&1
                sleep 1
                pg_url_works "$probe_url" "$LITELLM_DB_PASSWORD"; }; then
            LITELLM_DB_URL="postgresql://litellm:${LITELLM_DB_PASSWORD}@${socket_tail}"
        elif [ "$DOCKER_MODE" = "true" ]; then
            # No TCP fallback exists under --docker: 127.0.0.1 inside the
            # container is the container's own loopback (bridge network, no
            # host-gateway by design — see CLAUDE.md "Docker mode"), so a TCP
            # URL is guaranteed dead there. Commit the socket URL anyway: the
            # container's auth path differs from this host-side probe only in
            # UID, which the scram rule doesn't consult.
            LITELLM_DB_URL="postgresql://litellm:${LITELLM_DB_PASSWORD}@${socket_tail}"
            warn "Postgres socket auth failed — committing the socket URL anyway (no TCP fallback can work inside the container). Check the 'local litellm litellm scram-sha-256' line in pg_hba.conf and that the role password matches LITELLM_DB_PASSWORD in ~/.config/litellm/env, then re-run setup.sh"
        else
            LITELLM_DB_URL="postgresql://litellm:${LITELLM_DB_PASSWORD}@127.0.0.1:${pg_port}/litellm"
            warn "Postgres socket auth failed — keeping the TCP URL. Check the 'local litellm litellm scram-sha-256' line in pg_hba.conf and that the role password matches LITELLM_DB_PASSWORD in ~/.config/litellm/env, then re-run setup.sh"
        fi
    fi

    LITELLM_ENV_CONTENT+="DATABASE_URL=${LITELLM_DB_URL}"$'\n'
    LITELLM_ENV_CONTENT+="STORE_MODEL_IN_DB=True"$'\n'
    [ -n "${LITELLM_DB_PASSWORD:-}" ] && LITELLM_ENV_CONTENT+="LITELLM_DB_PASSWORD=${LITELLM_DB_PASSWORD}"$'\n'
    # LITELLM_SALT_KEY encrypts DB-stored model credentials at rest ("set once,
    # never change" — litellm production docs; rotating it makes them
    # unreadable, so it is persisted like the DB password and NEVER
    # regenerated). Without it litellm falls back to signing with the MASTER
    # key, which welds credential encryption to the admin credential — a later
    # master-key rotation would brick every /ui-added model. First write uses
    # the master key the deployed service last ran with, deliberately: that is the
    # docs-sanctioned safe migration for boxes whose stored models are already
    # encrypted under the fallback (same signing key, cryptographic no-op), and
    # from then on the master key is free to rotate. Read from the env file,
    # NOT from $ANTHROPIC_AUTH_TOKEN — on a run that also rotates the master
    # key the two differ, and seeding from the new value would pin the salt to
    # a key those rows were never encrypted with (unrecoverable). Falls back to
    # the current key only on a fresh box, where no encrypted rows exist.
    LITELLM_SALT_KEY="${PERSISTED_SALT_KEY:-${PERSISTED_MASTER_KEY:-${ANTHROPIC_AUTH_TOKEN}}}"
    # Never write this key empty. litellm's _get_salt_key() falls back to the
    # master key only when os.getenv returns None — an empty value is used
    # VERBATIM, so `LITELLM_SALT_KEY=` signs every credential with sha256("")
    # and, because the key is latched forever with no re-encryption path, that
    # is unrecoverable. Unreachable on today's mode matrix (a local LiteLLM
    # implies a gateway, which implies a minted master key), but the invariant
    # is not local to this line, so assert it rather than assume it.
    if [ -z "$LITELLM_SALT_KEY" ]; then
        error "Refusing to write an empty LITELLM_SALT_KEY — it would make every /ui-stored credential permanently unreadable. No master key was available to seed it; check ANTHROPIC_AUTH_TOKEN in ~/.profile and re-run."
        exit 1
    fi
    LITELLM_ENV_CONTENT+="LITELLM_SALT_KEY=${LITELLM_SALT_KEY}"$'\n'
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
            stop_user_service litellm
            # systemd may read the unit inactive while the rootless daemon still
            # runs the container — the compose file this repo deploys now sets
            # `restart: "no"`, but an OLDER deployed copy carried
            # `restart: unless-stopped`, and either way a stop that never fired
            # its ExecStop leaves an orphan holding 127.0.0.1:4000 — fatal for a
            # docker->native switch (the native proxy can't bind). Tear the compose
            # project down directly, independent of the unit state. Idempotent; if
            # the daemon/socket is down there's no running container to orphan.
            if [ "$installed_litellm_variant" = "docker" ] && [ -f "${LITELLM_CONFIG_DIR}/docker-compose.yml" ]; then
                litellm_compose down --remove-orphans 2>/dev/null || true
            fi
        fi
    fi

    # Postgres-gate rendering for BOTH unit variants: with a local cluster
    # (pg_port set by Phase 6) substitute its port into the units' bounded
    # pg_isready ExecStartPre; with an external DATABASE_URL delete the line —
    # a remote DB is not probeable by local pg_isready, and the deploy helper
    # refuses renders that still carry a __TOKEN__, so deletion is the only
    # correct external-DB shape. Port value is digits-only (pg_setting), safe
    # inside the sed replacement.
    pg_wait_sed=(-e '/__PGPORT__/d')
    if [ -n "${pg_port:-}" ]; then
        pg_wait_sed=(-e "s|__PGPORT__|${pg_port}|g")
    fi

    if [ "$DOCKER_MODE" = "true" ]; then
        # Dockerized LiteLLM: render the compose template (__PORT__) next to
        # config.yaml + env (the unit's WorkingDirectory is __APP_DIR__, so
        # `docker compose` auto-discovers docker-compose.yml and the relative
        # ./config.yaml + ./env mounts). The systemd --user unit runs
        # `docker compose up` against the rootless daemon. Postgres +
        # claude-devtools stay native.
        if render_template_if_changed "$SCRIPT_DIR/configs/litellm-docker-compose.yml" \
            "${LITELLM_CONFIG_DIR}/docker-compose.yml" "docker-compose.yml" \
            -e "s|__PORT__|${LITELLM_PORT}|g" \
            -e "s|__LITELLM_IMAGE_TAG__|${LITELLM_VERSION}|g"; then
            LITELLM_CHANGED=1
        fi
        log "LiteLLM docker-compose deployed to ${LITELLM_CONFIG_DIR}/docker-compose.yml"

        if deploy_user_systemd_service litellm "$SCRIPT_DIR/systemd/litellm-docker.service" \
            -e "s|__APP_DIR__|${LITELLM_CONFIG_DIR}|g" \
            -e "s|__PATH__|${USER_TOOL_PATH}|g" \
            "${pg_wait_sed[@]}"; then
            LITELLM_CHANGED=1
        fi

        # Pre-pull the image in the foreground (visible progress) so the unit
        # start below is fast and wait_for_litellm's budget isn't eaten by a
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
            -e "s|__PATH__|${LITELLM_PATH}|g" \
            "${pg_wait_sed[@]}"; then
            LITELLM_CHANGED=1
        fi
    fi

    # Port-capture check, before any start below. LiteLLM silently relocates:
    # `if port == 4000 and _is_port_in_use(port): port = random.randint(...)`
    # (proxy_cli.py) — hardcoded to 4000, which is exactly LITELLM_PORT. So if
    # anything else already holds the port (a SIGKILL-orphaned litellm, a
    # container the rootless daemon still runs, a hand-started instance), the
    # new proxy starts successfully on a random port and says nothing, while
    # wait_for_litellm gets its 200 from the STALE backend and this run reports
    # success. Same wrong-backend shape as Postgres port capture. The unit's own
    # stop covers the runtime-switch case; this catches everything else.
    # Warn-only: the port may legitimately be held by the unit we are about to
    # restart, and we cannot attribute a socket to a unit without extra tooling.
    # The /dev/tcp open happens inside a subshell, so the descriptor is closed by
    # that subshell exiting — nothing to clean up in this shell.
    if [ "$LITELLM_CLIENT_BROKEN" != "1" ] \
        && ! systemctl --user is-active --quiet litellm \
        && (exec 3<>"/dev/tcp/127.0.0.1/${LITELLM_PORT}") 2>/dev/null; then
        warn "Port ${LITELLM_PORT} is already in use while litellm is not running — LiteLLM would silently start on a RANDOM port instead (proxy_cli.py relocates when 4000 is taken). Find the holder (ss -lptn 'sport = :${LITELLM_PORT}') and stop it, then re-run setup.sh"
    fi

    # Enable + restart only when something the service consumes actually
    # changed (env file, config, unit, compose render, binary upgrade, runtime
    # switch) — an unconditional restart made every no-op re-run reboot
    # LiteLLM (Prisma reconnect + boot-time model-map fetch, 5-25s) and drop
    # in-flight gateway connections. Called bare: a failed restart aborts
    # under `set -e`.
    if [ "$LITELLM_CLIENT_BROKEN" = "1" ]; then
        # Phase 4a could not generate the Prisma client: config/env/unit are
        # deployed (the next run only needs the regen), but a start would
        # crash on import and churn through the start limit. Keep it down —
        # stop is a free no-op on an inactive unit and cancels any queued
        # restart; `enable` is left alone so a later `systemctl --user start`
        # or reboot behaves as before.
        stop_user_service litellm
        warn "LiteLLM left stopped — ${LITELLM_CLIENT_BROKEN_WHY:-Prisma client} failure in Phase 4a; see the banner at the end"
    else
        # In native mode this is the run's ONLY litellm start (Phase 4a stops
        # the unit for the venv/toolchain work and defers the start here); an
        # inactive unit is started even when nothing changed.
        restart_user_service_if_stale litellm "$LITELLM_CHANGED"

        # Liveliness budget: long only when the unit was started this run
        # (read the action taken, not the staleness rule) — such a start may
        # spend minutes in the bounded startup schema sync on a CPU-starved VM
        # (wait_for_litellm's docstring; safe because it bails early on a
        # failed or crash-looping unit). An untouched running service (docker
        # no-op runs) keeps the short budget.
        litellm_wait_budget="$LITELLM_WAIT_SHORT"
        if [ "${USER_SERVICE_RESTARTED:-0}" = "1" ]; then
            litellm_wait_budget="$LITELLM_WAIT_LONG"
        fi
        # The success arm is the DNS pre-flight: can LiteLLM resolve the
        # providers it is configured to dial? Nothing else in the run asks —
        # /health/readiness passes without ever touching them, so a box where
        # every model call will hang looks fully healthy (CLAUDE.md >
        # Troubleshooting, "Temporary failure in name resolution").
        # It belongs on THIS arm, not after the wait: the banner it feeds opens
        # "LiteLLM is running, but…", so on a proxy that never answered it would
        # contradict the warning below and spend 15-30s per host diagnosing DNS
        # on a box whose problem is upstream of it. The LITELLM_CLIENT_BROKEN
        # path above never reaches here at all.
        # Warn-only and never fatal: DNS is not this script's to fix, an
        # endpoint may legitimately be unreachable from this box, and a
        # transient failure must not fail an otherwise complete deployment.
        if wait_for_litellm "$LITELLM_PORT" "$litellm_wait_budget"; then
            for _dns_host in $(litellm_endpoint_hosts "$LITELLM_ENV_FILE"); do
                case "$(endpoint_dns_state "$_dns_host")" in
                    ok) ;;
                    v4only)
                        ENDPOINT_DNS_V4_ONLY+=("$_dns_host")
                        warn "${_dns_host} resolves over IPv4 but its dual-stack lookup fails — LiteLLM uses getaddrinfo, so model calls will intermittently fail with 'Temporary failure in name resolution'. See the banner at the end" ;;
                    dead)
                        ENDPOINT_DNS_DEAD+=("$_dns_host")
                        warn "${_dns_host} does not resolve — model calls to it will fail. Check the endpoint value in ~/.config/litellm/env and this box's resolver. See the banner at the end" ;;
                    # endpoint_dns_state prints one of three words; anything else
                    # is a bug in IT, not a finding about the host — say so
                    # rather than filing the host under `dead` and sending the
                    # operator after a resolver that is fine.
                    *)  warn "endpoint_dns_state returned an unexpected value for ${_dns_host} — skipping its DNS check" ;;
                esac
            done
            unset _dns_host
        else
            warn "LiteLLM may not be ready — Claude Code calls could fail until it starts"
        fi
    fi
    # The Phase 4a abort belt is obsolete past the authoritative start above
    # (a no-op under --docker, where 4a never armed it).
    trap - EXIT
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
    # Rendered through the shared guard (empty / sed failure / leftover
    # __TOKEN__), then placed with `sudo install` — which is why this can't use
    # render_template_if_changed, whose placement is write_if_changed. Not
    # theoretical for a policy file: an empty render would install a
    # managed-settings.json with NO permissions.deny[], and a surviving
    # __REPO_DIR__ would install one whose PreToolUse hook path does not exist
    # (bash exits 127, Claude Code treats that as a non-blocking error, and the
    # root-enforced exit-2 rm/push floor is silently gone). On refusal keep the
    # previous good copy.
    if ! render_template_or_fail "$SCRIPT_DIR/configs/claude-managed-settings.json" \
            "managed-settings.json" -e "s|__REPO_DIR__|${REPO_DIR}|g" > "$MANAGED_TMP"; then
        error "Keeping the existing /etc/claude-code/managed-settings.json"
    elif cmp -s "$MANAGED_TMP" /etc/claude-code/managed-settings.json 2>/dev/null; then
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
        # The grep drops pre-release tags (a version-shaped name containing a
        # `-`, i.e. v2.0.0-rc1 / 1.9.0-beta): git's versionsort ranks a
        # suffixed tag ABOVE its release (v2.0.0-rc1 > v2.0.0) unless
        # versionsort.suffix is configured, and even with it a newer version's
        # rc with no final yet still sorts first — so an upstream rc/beta push
        # would otherwise silently become the pinned "latest release tag".
        CLAUDE_DEVTOOLS_LATEST_TAG=$(cd "$CLAUDE_DEVTOOLS_DIR" && git ls-remote --refs --tags --sort=-v:refname origin 'v*' 2>/dev/null | grep -vE 'refs/tags/v?[0-9][^/]*-' | head -1 | awk -F'refs/tags/' '{print $2}' || true)
        if [ -z "$CLAUDE_DEVTOOLS_LATEST_TAG" ]; then
            CLAUDE_DEVTOOLS_LATEST_TAG=$(cd "$CLAUDE_DEVTOOLS_DIR" && git ls-remote --refs --tags --sort=-v:refname origin 2>/dev/null | grep -vE 'refs/tags/v?[0-9][^/]*-' | head -1 | awk -F'refs/tags/' '{print $2}' || true)
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
# -L, not bun_global_present: a DANGLING claude-run symlink still needs the
# `bun remove -g` + link cleanup below (the helper deliberately reports a
# dangling link as absent, which is right for install-if-missing, wrong here).
if [ -f "$LEGACY_HISTORY_SERVICE" ] || [ -L "$LEGACY_CLAUDE_RUN_BIN" ] || bun_global_present claude-run; then
    log "=== Phase 10: removing legacy claude-run + claude-history service ==="
    if [ -f "$LEGACY_HISTORY_SERVICE" ]; then
        systemctl --user disable --now claude-history &>/dev/null || true
        rm -f "$LEGACY_HISTORY_SERVICE"
        systemctl --user daemon-reload &>/dev/null || true
        log "Removed claude-history.service"
    fi
    if [ -L "$LEGACY_CLAUDE_RUN_BIN" ] || bun_global_present claude-run; then
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
    # Non-fatal: every deployment step already succeeded by here, so a held
    # dpkg lock (unattended-upgrades) or a broken package state must not abort
    # under `set -e` and take the end-of-run banners with it — the LiteLLM UI
    # credentials, the red "Prisma client missing" banner, and the
    # model-config instructions are all printed below this line.
    sudo apt-get autoremove -y || warn "apt autoremove failed — harmless, run it by hand later"
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

# NOT tty-gated, unlike the credential banner above: this is the only place
# the deliberate "LiteLLM left stopped" outcome is explained, and the run
# still exits 0 by design (an overlay's remaining phases must not be aborted
# by a gateway that could not be installed) — so a `| tee` / overlay caller
# must see it in the captured output, not just an interactive user.
if [ "$LITELLM_CLIENT_BROKEN" = "1" ]; then
    echo -e "${RED}${rule}${NC}"
    case "$LITELLM_CLIENT_BROKEN_WHY" in
        install)
            echo -e "${RED}  LiteLLM is NOT running: Phase 4a could not install LiteLLM ${LITELLM_VERSION} into its"
            echo -e "  venv (uv tool install failed — see the [ERROR] lines above). The unit was left"
            echo -e "  stopped on purpose (it has nothing to run / would crash on import).${NC}"
            echo ""
            echo -e "${YELLOW}  Next steps:${NC}"
            echo -e "    1. Most likely cause on these boxes: the exact pin has not aged past the uv"
            echo -e "       cooldown (${GREEN}~/.config/uv/uv.toml${NC} exclude-newer) — wait it out, or temporarily"
            echo -e "       relax it. Otherwise: network to pypi.org / python build, disk space."
            echo -e "    2. Re-run ${GREEN}${SCRIPT_DIR}/setup.sh${NC} — it installs, generates the Prisma client"
            echo -e "       and starts LiteLLM."
            ;;
        toolchain)
            echo -e "${RED}  LiteLLM is NOT running: Phase 4a could not use the venv's Prisma toolchain"
            echo -e "  (see the [ERROR] lines above). The unit was left stopped on purpose —"
            echo -e "  starting it would only crash-loop on \"The Client hasn't been generated\".${NC}"
            echo ""
            echo -e "${YELLOW}  Next steps — this is NOT a network failure; both causes are local:${NC}"
            echo -e "    1. Either the venv has no ${GREEN}bin/prisma${NC} (an install above failed — see its"
            echo -e "       [ERROR]/[WARNING] line), or ${GREEN}PRISMA_BINARY_CACHE_DIR${NC} in"
            echo -e "       ${GREEN}~/.config/litellm/prisma.env${NC} is not an absolute path (hand-edited, or a"
            echo -e "       failed render — delete that file, it is redeployed from the repo template)."
            echo -e "    2. Re-run ${GREEN}${SCRIPT_DIR}/setup.sh${NC}."
            ;;
        *)
            echo -e "${RED}  LiteLLM is NOT running: Phase 4a could not generate the Prisma client"
            echo -e "  (see the [ERROR] lines above). The unit was left stopped on purpose —"
            echo -e "  starting it would only crash-loop on \"The Client hasn't been generated\".${NC}"
            echo ""
            echo -e "${YELLOW}  Next steps:${NC}"
            echo -e "    1. Fix the cause reported above (network to binaries.prisma.sh /"
            echo -e "       registry.npmjs.org / nodejs.org, disk, or a stalled child — during"
            echo -e "       a stall run: ${GREEN}ps -eo pid,ppid,stat,etimes,args --forest | grep -E 'prisma|node|npm'${NC})."
            echo -e "    2. Re-run ${GREEN}${SCRIPT_DIR}/setup.sh${NC} — it re-heals the toolchain, regenerates the"
            echo -e "       client (import probe) and starts LiteLLM."
            ;;
    esac
    echo -e "${RED}${rule}${NC}"
    echo ""
fi

if [ "$NEEDS_MODEL_CONFIG" = "1" ] && [ -t 1 ]; then
    echo -e "${YELLOW}${rule}${NC}"
    echo -e "${YELLOW}  No Azure credentials in .env — setup completed, but Claude Code"
    echo -e "  has NO default model configured yet.${NC}"
    echo ""
    echo -e "${YELLOW}  Next steps:${NC}"
    echo -e "    1. Open ${GREEN}http://127.0.0.1:${LITELLM_PORT}/ui${NC} and add at least one model."
    echo -e "    2. Edit ${GREEN}~/.profile${NC} and set the four default-model vars to the"
    echo -e "       Public Model Name you added (same name works for all four):"
    echo -e "         ${GREEN}export ANTHROPIC_DEFAULT_HAIKU_MODEL=\"<name>\"${NC}"
    echo -e "         ${GREEN}export ANTHROPIC_DEFAULT_SONNET_MODEL=\"<name>\"${NC}"
    echo -e "         ${GREEN}export ANTHROPIC_DEFAULT_OPUS_MODEL=\"<name>\"${NC}"
    echo -e "         ${GREEN}export ANTHROPIC_DEFAULT_FABLE_MODEL=\"<name>\"${NC}"
    echo -e "    3. ${GREEN}source ~/.profile${NC} (or log out and back in) before \`claude\`."
    echo -e "${YELLOW}${rule}${NC}"
    echo ""
fi

if [ "$WARN_STRAY_ANTHROPIC_KEY" = "1" ] && [ -t 1 ]; then
    echo -e "${YELLOW}${rule}${NC}"
    echo -e "${YELLOW}  ANTHROPIC_API_KEY is exported in your shell profile. Claude Code"
    echo -e "  prefers it over ANTHROPIC_AUTH_TOKEN (sent as x-api-key), so requests"
    echo -e "  to the LiteLLM gateway will fail with 401.${NC}"
    echo ""
    echo -e "${YELLOW}  Fix: move the key into ${GREEN}.env${YELLOW} in the repo root and delete the export"
    echo -e "  from ~/.profile / ~/.bashrc / ~/.zshrc — setup still delivers it to"
    echo -e "  LiteLLM (~/.config/litellm/env) for a real-Anthropic upstream.${NC}"
    echo -e "${YELLOW}${rule}${NC}"
    echo ""
fi

# Not tty-gated: the per-host Phase 7 warnings point at this banner by name.
if [ ${#ENDPOINT_DNS_V4_ONLY[@]} -gt 0 ] || [ ${#ENDPOINT_DNS_DEAD[@]} -gt 0 ]; then
    echo -e "${YELLOW}${rule}${NC}"
    echo -e "${YELLOW}  LiteLLM is running, but it cannot resolve provider endpoints it is"
    echo -e "  configured to call. /ui and login will work; model calls will not.${NC}"
    echo ""
    if [ ${#ENDPOINT_DNS_V4_ONLY[@]} -gt 0 ]; then
        echo -e "${YELLOW}  IPv4 resolves, dual-stack does not: ${ENDPOINT_DNS_V4_ONLY[*]}${NC}"
        echo -e "${YELLOW}  glibc queries A and AAAA in parallel and fails the whole lookup when"
        echo -e "  the AAAA leg times out.${NC}"
        echo ""
        echo -e "${YELLOW}  Confirm (temporary — NetworkManager rewrites this file on the next"
        echo -e "  connection change):${NC}"
        echo -e "    ${GREEN}sudo sh -c 'echo \"options single-request-reopen\" >> /etc/resolv.conf'${NC}"
        echo -e "    ${GREEN}# or, to drop the AAAA query entirely: options no-aaaa${NC}"
        echo ""
        echo -e "${YELLOW}  Then persist it:${NC}"
        echo -e "    ${GREEN}C=\$(nmcli -g NAME connection show --active | head -1)${NC}"
        echo -e "    ${GREEN}nmcli connection modify \"\$C\" ipv4.dns-options single-request-reopen${NC}"
        echo -e "    ${GREEN}nmcli connection up \"\$C\"${NC}"
        echo ""
    fi
    if [ ${#ENDPOINT_DNS_DEAD[@]} -gt 0 ]; then
        echo -e "${YELLOW}  Does not resolve at all: ${ENDPOINT_DNS_DEAD[*]}${NC}"
        echo -e "${YELLOW}  Check the endpoint value in ${GREEN}~/.config/litellm/env${YELLOW} (a deleted or"
        echo -e "  renamed cloud resource looks exactly like this), then this box's"
        echo -e "  resolver: ${GREEN}getent ahosts <host>${YELLOW} and ${GREEN}cat /etc/resolv.conf${YELLOW}.${NC}"
        echo ""
    fi
    echo -e "${YELLOW}  Full runbook: CLAUDE.md > Troubleshooting,"
    echo -e "  \"Temporary failure in name resolution\".${NC}"
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

#!/bin/bash
#
# Shared utility functions for claude-litellm setup
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Source guard - prevent double-sourcing
[[ -n "${_CB_COMMON_SOURCED:-}" ]] && return
_CB_COMMON_SOURCED=1

#############################################################################
# Colors
#############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#############################################################################
# Configuration
#############################################################################

# Shell profile file we write env-vars into. ~/.profile is sourced by bash
# login shells and (via ~/.zprofile chain on most distros) by zsh login shells;
# non-login shells inherit the env from the parent login shell. One constant,
# used by every reader/writer below — there is deliberately no multi-file
# machinery (nothing in this repo needs a second profile file).
PROFILE_FILE="${HOME}/.profile"

# Set to 1 by every code path that changes apt state (apt_install below, plus
# install_docker_rootless's conflicting-package removes); setup.sh Phase 11
# runs `apt-get autoremove` only when it fired. Initialized here because the
# writers live in this library — the flag must not depend on which phase runs
# first.
APT_CHANGED=0

# Set to 1 once `apt-get update` has run this invocation; apt_install refreshes
# the index at most once per run. install_docker_rootless re-runs the update
# itself after adding the Docker apt repo (a new source needs a re-index) and
# then re-marks the index fresh.
APT_INDEX_FRESH=0

#############################################################################
# Hardened curl
#############################################################################

# Hardened curl for external HTTPS requests — enforces TLS 1.2+ and HTTPS-only.
# -q (must come first) makes curl ignore the user's curlrc. REMnux ships ~/.curlrc with
# an ancient/malformed IE11 User-Agent (a doubled "User-Agent: User-Agent: ..." for
# malware-analysis browser spoofing) plus custom Accept/Connection headers; that config
# is read by EVERY curl on the box and trips Cloudflare's bot challenge (HTTP 403,
# cf-mitigated: challenge) on hosts like claude.ai. -q isolates our downloads from it.
# Do NOT use for localhost/health checks (plain HTTP).
curl_secure() {
    curl -q --proto '=https' --tlsv1.2 "$@"
}

#############################################################################
# Package state
#############################################################################

# True when dpkg reports the package fully installed. `dpkg -s` alone is not
# enough — it also returns 0 for removed-but-not-purged packages (config-files
# state), which would wrongly skip a needed (re)install.
# Usage: pkg_installed <package>
pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

# Refresh the apt index at most once per run (see APT_INDEX_FRESH above).
apt_update_once() {
    [ "$APT_INDEX_FRESH" = "1" ] && return 0
    sudo apt-get update && APT_INDEX_FRESH=1
}

# apt-get update (once per run) + install; sets APT_CHANGED so setup.sh
# Phase 11's autoremove gate fires. Fatality follows the call site: called
# bare, a failed update/install aborts under `set -e` (Phases 2/6); called in
# a condition (`apt_install pkg || warn …`), failures are the caller's to
# handle and APT_CHANGED stays unset (the && short-circuit).
# Usage: apt_install <package|deb-path>...
apt_install() {
    apt_update_once
    sudo apt-get install -y "$@" && APT_CHANGED=1
}

# True when a bun-installed global binary is present AND usable. bun globals
# are symlinks into the package store; -x follows the link, so a dangling
# symlink (stale lockfile / pruned store) reads as absent — which is correct
# for the install-if-missing callers: a dangling link IS the broken state, and
# re-running `bun add -g` is exactly the repair. (An `-L` test here would
# report the broken link as "already installed" and strand the box: e.g. a
# dangling pnpm makes every later claude-devtools build fail with no code path
# that fixes it.) Callers that want "any link, working or not" — the legacy
# claude-run cleanup — test -L themselves.
# Usage: bun_global_present <binary-name>
bun_global_present() {
    [ -x "${HOME}/.bun/bin/$1" ]
}

#############################################################################
# Logging
#############################################################################

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

#############################################################################
# Resilient script installer
#############################################################################

# Download <url> to <dest> with retries and a non-empty check. Avoids the
# silent-failure trap of a bare `curl -o` / `curl | sh`: a transient
# 403/network blip yields an empty or missing file a later step trips over
# with a confusing error. Checks curl's real exit + a non-empty body, retries
# twice. Returns 1 after 3 failed attempts (caller owns <dest> cleanup either
# way). Warns go to stdout like every other message — do NOT call this inside
# a $(...) capture.
# Usage: download_to_file <url> <dest> <label>
download_to_file() {
    local url="$1" dest="$2" label="$3" attempt
    # Present a modern browser User-Agent: installer CDNs (e.g. claude.ai behind
    # Cloudflare) return 403 for non-browser/odd UAs. -A also overrides any curlrc UA
    # on the command line (curl_secure already passes -q; this is belt-and-suspenders).
    local ua="Mozilla/5.0 (X11; Linux x86_64; rv:140.0) Gecko/20100101 Firefox/140.0"
    # Bound each attempt: --connect-timeout caps a blackholed connect (without
    # it, 3 attempts on a firewalled box hang for minutes each); --speed-limit/
    # --speed-time abort a stalled transfer without capping legitimately slow
    # but progressing downloads (the Obsidian .deb is ~100MB).
    for attempt in 1 2 3; do
        if curl_secure -fsSL -A "$ua" --connect-timeout 15 --speed-limit 1024 --speed-time 60 \
                "$url" -o "$dest" && [ -s "$dest" ]; then
            return 0
        fi
        if [ "$attempt" -lt 3 ]; then
            warn "$label download failed (attempt ${attempt}/3) — retrying in 5s..."
            sleep 5
        fi
    done
    warn "Could not download $label from $url after 3 attempts"
    return 1
}

# Download a remote shell installer to a temp file and run it (stdin closed,
# non-interactive). Returns 0 if the installer ran (its own non-zero exit is
# warned, not fatal), 1 if the download failed after all attempts. Callers
# verify the resulting binary themselves.
# Usage: download_and_run <url> <label> [interpreter]   (interpreter defaults to bash)
download_and_run() {
    local url="$1" label="$2" interp="${3:-bash}"
    local tmp
    tmp="$(mktemp)"
    if download_to_file "$url" "$tmp" "$label installer"; then
        "$interp" "$tmp" </dev/null || warn "$label installer exited non-zero"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

#############################################################################
# Profile Management (bash + zsh)
#############################################################################

# Reverse the escaping update_profile_export applies to a double-quoted value
# (inverse order of the forward escapes). Single source of truth for the
# scheme — read_profile_export and collect_litellm_provider_vars both decode
# through this, so extending the writer means extending exactly one inverse.
# Returns via REPLY (not stdout) so callers stay fork-free — the collector
# decodes every export line in ~/.profile, and a $(...) per line adds ~36
# subshells per setup run.
# Usage: _profile_unescape "raw-value-between-quotes"; use "$REPLY"
_profile_unescape() {
    REPLY="$1"
    REPLY="${REPLY//\\\`/\`}"
    REPLY="${REPLY//\\\$/\$}"
    REPLY="${REPLY//\\\"/\"}"
    REPLY="${REPLY//\\\\/\\}"
}

# Idempotently set an export in PROFILE_FILE.
# Writes "export NAME=\"value\"" with proper escaping.
# Usage: update_profile_export VAR_NAME "value"
update_profile_export() {
    local var_name="$1"
    local var_value="$2"

    ensure_managed_bash_profile

    # Escape special characters for shell double-quoted string
    local escaped_value="$var_value"
    escaped_value="${escaped_value//\\/\\\\}"    # \ -> \\
    escaped_value="${escaped_value//\"/\\\"}"    # " -> \"
    escaped_value="${escaped_value//\$/\\\$}"    # $ -> \$
    escaped_value="${escaped_value//\`/\\\`}"    # ` -> \`

    # For sed replacement, also escape & (special in the replacement string)
    # and | (the s||| delimiter — an unescaped one truncates the expression).
    local sed_value="$escaped_value"
    sed_value="${sed_value//&/\\&}"              # & -> \&
    sed_value="${sed_value//|/\\|}"              # | -> \|

    [ ! -f "$PROFILE_FILE" ] && touch "$PROFILE_FILE"
    # Already exactly this line? Skip the sed -i full-file rewrite — with
    # ~36 calls per setup run this keeps a no-op re-run from rewriting
    # ~/.profile dozens of times.
    if grep -qxF "export ${var_name}=\"${escaped_value}\"" "$PROFILE_FILE" 2>/dev/null; then
        return 0
    fi
    if grep -q "^export ${var_name}=" "$PROFILE_FILE" 2>/dev/null; then
        sed -i "s|^export ${var_name}=.*|export ${var_name}=\"${sed_value}\"|" "$PROFILE_FILE"
    elif grep -q "^#[[:space:]]*export ${var_name}=" "$PROFILE_FILE" 2>/dev/null; then
        sed -i "s|^#[[:space:]]*export ${var_name}=.*|export ${var_name}=\"${sed_value}\"|" "$PROFILE_FILE"
    else
        echo "export ${var_name}=\"${escaped_value}\"" >> "$PROFILE_FILE"
    fi
}

# Read a previously written value from PROFILE_FILE. Prints nothing if not
# present.
# Usage: read_profile_export VAR_NAME
read_profile_export() {
    local var_name="$1"
    local line

    [ -f "$PROFILE_FILE" ] || return 0
    line=$(grep "^export ${var_name}=" "$PROFILE_FILE" 2>/dev/null | head -1)
    [ -z "$line" ] && return 0
    local raw="${line#export ${var_name}=}"
    local value
    # update_profile_export always writes the double-quoted form, but a user
    # may hand-edit an unquoted (or single-quoted) line. Strip the quoting we
    # actually find instead of assuming double quotes: a blind
    # `${line#export VAR=\"}` no-ops on an unquoted line and would return the
    # WHOLE line as the value — which callers then re-persist (e.g. the master
    # key), destroying the user's real value.
    case "$raw" in
        '"'*'"') value="${raw%\"}"; value="${value#\"}"; _profile_unescape "$value"; value="$REPLY" ;;
        "'"*"'") value="${raw%\'}"; value="${value#\'}" ;;
        *)       value="$raw" ;;
    esac
    printf '%s' "$value"
}

# Delete any `export VAR_NAME=...` line from PROFILE_FILE, and unset the var
# in the current shell so the rest of setup.sh doesn't inherit a value we
# just decided to scrub.
# Usage: remove_profile_export VAR_NAME
remove_profile_export() {
    local var_name="$1"

    if [ -f "$PROFILE_FILE" ] && grep -q "^export ${var_name}=" "$PROFILE_FILE" 2>/dev/null; then
        sed -i "/^export ${var_name}=/d" "$PROFILE_FILE"
    fi

    unset -- "$var_name"
}

# Canonicalize an Azure endpoint to the v1 API surface the `openai/` LiteLLM
# route requires: `https://<host>/openai/v1`.
#
# The `openai/` provider builds its URL as `{api_base}/responses`, so api_base
# must carry no trailing slash and no query string — `…/openai/v1?api-version=preview`
# would otherwise yield `…/openai/v1?api-version=preview/responses` (404).
#
# Accepts any form a user is likely to paste; all three Azure hostnames
# (services.ai / openai / cognitiveservices) expose the same /openai/v1 path:
#   https://X.services.ai.azure.com            -> https://X.services.ai.azure.com/openai/v1
#   https://X.services.ai.azure.com/openai     -> https://X.services.ai.azure.com/openai/v1
#   https://X.services.ai.azure.com/openai/v1/ -> https://X.services.ai.azure.com/openai/v1
#   <empty>                                    -> <empty>
normalize_azure_v1_endpoint() {
    local url="${1:-}"
    [ -n "$url" ] || return 0
    url="${url%%\?*}"                                        # drop query string
    url="${url%%#*}"                                         # drop fragment
    while [ "${url%/}" != "$url" ]; do url="${url%/}"; done  # drop trailing slashes
    url="${url%/openai/v1}"                                  # drop an existing v1 suffix
    url="${url%/openai}"                                     # ...or a bare /openai suffix
    while [ "${url%/}" != "$url" ]; do url="${url%/}"; done
    printf '%s' "${url}/openai/v1"
}

# Emit `KEY=VALUE` lines for every LiteLLM-relevant provider env var found in
# the current shell environment or ~/.profile. Output is intended to be
# concatenated into the LiteLLM systemd EnvironmentFile.
#
# Coverage (verified by grepping get_secret/os.environ.get in upstream LiteLLM):
#   - Pattern: <PROVIDER>_API_{KEY,BASE,VERSION,TOKEN}  (covers ~120 vars)
#   - Plus AWS / GCP / Vertex / watsonx / Azure-AD / OpenAI-org / HF_TOKEN extras
#   - Excludes master key, base URL, internal LITELLM_/UI_ config
#
# Priority when a var is set in multiple places: current env > ~/.profile.
collect_litellm_provider_vars() {
    local pattern='^[A-Z][A-Z0-9_]*_(API_KEY|API_BASE|API_VERSION|API_TOKEN)$'
    local named=(
        AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
        AWS_REGION_NAME AWS_DEFAULT_REGION AWS_REGION AWS_BEARER_TOKEN_BEDROCK
        GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CLOUD_PROJECT GOOGLE_API_KEY
        VERTEXAI_PROJECT VERTEXAI_LOCATION VERTEX_PROJECT VERTEX_LOCATION
        WATSONX_PROJECT_ID WATSONX_REGION WX_PROJECT_ID WX_REGION
        AZURE_RESOURCE_ENDPOINT AZURE_CLIENT_SECRET AZURE_AD_TOKEN
        OPENAI_ORGANIZATION OPENAI_PROJECT
        HF_TOKEN
    )
    local exclude='^(ANTHROPIC_AUTH_TOKEN|ANTHROPIC_BASE_URL|LITELLM_|UI_)'

    declare -A seen profile
    local v val line

    # Build ~/.profile export map in a single pass (decoded via
    # _profile_unescape, the shared inverse of update_profile_export's
    # escaping). Used by Passes 2 + 3 below.
    if [ -f "$PROFILE_FILE" ]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^export[[:space:]]+([A-Z][A-Z0-9_]*)=\"(.*)\"$ ]] || continue
            v="${BASH_REMATCH[1]}"
            _profile_unescape "${BASH_REMATCH[2]}"
            profile[$v]="$REPLY"
        done < "$PROFILE_FILE"
    fi

    # Pass 1: pattern-match current shell env
    while IFS= read -r v; do
        [[ "$v" =~ $pattern ]] || continue
        [[ "$v" =~ $exclude ]] && continue
        val="${!v}"
        [ -z "$val" ] && continue
        printf '%s=%s\n' "$v" "$val"
        seen[$v]=1
    done < <(compgen -e)

    # Pass 2: named non-pattern vars (current env, fallback to profile map)
    for v in "${named[@]}"; do
        [ -n "${seen[$v]:-}" ] && continue
        val="${!v:-}"
        [ -z "$val" ] && val="${profile[$v]:-}"
        [ -z "$val" ] && continue
        printf '%s=%s\n' "$v" "$val"
        seen[$v]=1
    done

    # Pass 3: pattern-matched names found in ~/.profile but not in current env
    for v in "${!profile[@]}"; do
        [ -n "${seen[$v]:-}" ] && continue
        [[ "$v" =~ $pattern ]] || continue
        [[ "$v" =~ $exclude ]] && continue
        val="${profile[$v]}"
        [ -z "$val" ] && continue
        printf '%s=%s\n' "$v" "$val"
    done
}

# Ensure a PATH line exists in PROFILE_FILE (idempotent append).
ensure_path_in_profile() {
    local line="$1"

    ensure_managed_bash_profile
    [ ! -f "$PROFILE_FILE" ] && touch "$PROFILE_FILE"
    grep -qF "$line" "$PROFILE_FILE" 2>/dev/null || echo "$line" >> "$PROFILE_FILE"
}

# Ensure ~/.bash_profile sources ~/.profile so bash login shells pick up our env
# vars. Per bash(1) startup order, login shells read the first of ~/.bash_profile,
# ~/.bash_login, ~/.profile that exists and skip the rest. Tools that drop their
# own ~/.bash_profile (bun, uv, claude installers) would otherwise shadow .profile.
# A pre-existing ~/.bash_login is left alone: once the shim exists bash never
# reads it (first-of-three), so it's inert — deleting a user dotfile isn't ours
# to do.
#
# Policy: be a polite co-tenant. If the shim source line is already present,
# leave the file alone — don't wipe installer blocks appended below us. Only
# write when the line is missing (fresh file or someone clobbered the shim);
# preserve any existing content by prepending.
#
# Memoised: every update_profile_export call re-invokes this (~35×/run), but
# the shim can only change when an installer runs. Pass `force` at the
# re-assert sites after such a run (post-Claude-installer, end-of-run net);
# everything else hits the flag and returns fork-free.
# Usage: ensure_managed_bash_profile [force]
ensure_managed_bash_profile() {
    if [ "${1:-}" != "force" ] && [ -n "${_SHIM_ENSURED:-}" ]; then
        return 0
    fi
    _SHIM_ENSURED=1

    local shim="${HOME}/.bash_profile"
    local source_line='[ -f ~/.profile ] && . ~/.profile'

    if [ -f "$shim" ] && grep -qF "$source_line" "$shim"; then
        return 0
    fi

    local tmp
    tmp=$(mktemp)
    cat > "$tmp" <<'SHIM'
# claude-litellm managed shim — sources ~/.profile so bash login shells get the
# same environment whether bash chooses ~/.bash_profile or ~/.profile per its
# startup order. Deployed by claude-litellm setup.sh.
[ -f ~/.profile ] && . ~/.profile
SHIM
    if [ -f "$shim" ]; then
        echo "" >> "$tmp"
        cat "$shim" >> "$tmp"
    fi
    mv "$tmp" "$shim"
    chmod 644 "$shim"
}

# Prune stale native-installer binaries from ~/.local/share/claude/versions,
# keeping only the one the launcher points at (~300 MB each).
#
# Claude Code sweeps this directory itself on startup, but retains
# VERSION_RETENTION_COUNT=2 (a compile-time constant — no env var, no settings
# key) *plus* every protected version: the running executable, the
# ~/.local/bin/claude symlink target, and anything holding a live lock. Since
# the overlays pin the stable channel after an update, the symlink target is
# usually not among the two newest files, so the floor is three binaries.
#
# Precondition, borrowed from upstream: the launcher must be a symlink into the
# versions dir. When it is not, Claude Code skips its own cleanup entirely ("the
# launcher ... is externally managed, so the version(s) it needs cannot be
# determined") *and* `claude install` refuses to replace a launcher it does not
# own — a silent state worth surfacing. We bail out for the same reason it does:
# with no symlink there is no way to tell which binary is live.
prune_claude_versions() {
    local launcher versions_dir target running f size removed=0 freed=0

    launcher="$(command -v claude 2>/dev/null || echo "${HOME}/.local/bin/claude")"
    # Same resolution the binary uses (env-paths): XDG_DATA_HOME, else ~/.local/share.
    versions_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/claude/versions"
    [ -d "$versions_dir" ] || return 0

    if [ ! -L "$launcher" ]; then
        warn "Claude Code launcher ${launcher} is not a symlink — its built-in version cleanup is disabled and updates cannot replace it; remove the file and re-run 'claude install stable'"
        return 0
    fi
    target="$(readlink -f "$launcher" 2>/dev/null)" || return 0
    if [[ "$target" != "$versions_dir"/* ]]; then
        warn "Claude Code launcher ${launcher} resolves outside ${versions_dir} — skipping version prune"
        return 0
    fi

    # Binaries of live processes, collected once. Deleting a running executable
    # is harmless on Linux (the inode survives), but a session that re-execs
    # itself would lose its path, so leave those alone.
    running="$(readlink /proc/[0-9]*/exe 2>/dev/null || true)"

    for f in "$versions_dir"/*; do
        [ -f "$f" ] || continue
        [ "$f" = "$target" ] && continue
        # An install may be in flight; upstream's own 1h rule reaps these.
        case "$f" in *.tmp.*) continue ;; esac
        grep -qxF -- "$f" <<<"$running" && continue
        size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
        rm -f "$f" || continue
        removed=$((removed + 1))
        freed=$((freed + size))
    done

    if [ "$removed" -gt 0 ]; then
        log "Pruned ${removed} stale Claude Code version(s) — freed $((freed / 1024 / 1024)) MB"
    fi
    return 0
}

#############################################################################
# AppArmor (for bwrap sandbox used by Claude Code)
#############################################################################

# True when unprivileged user namespaces are AppArmor-restricted and no bwrap
# profile exists yet — the state configure_bwrap_apparmor fixes and the
# rootless-Docker preflight in install_docker_rootless warns about. A missing
# sysctl file reads as empty (≠ "1"), i.e. not restricted.
apparmor_userns_restricted() {
    [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" = "1" ] \
        && [ ! -f /etc/apparmor.d/bwrap ]
}

# Newer kernels restrict unprivileged user namespaces via AppArmor by default,
# which breaks bwrap sandboxing. Idempotent: only creates profile if absent.
configure_bwrap_apparmor() {
    # The extra guards beyond the predicate check we can actually write + load
    # a profile here (parser present, AppArmor module loaded).
    if ! command -v apparmor_parser &> /dev/null \
        || [ ! -d /sys/module/apparmor ] \
        || ! apparmor_userns_restricted; then
        log "AppArmor bwrap profile already configured or not needed"
        return 0
    fi
    log "Configuring AppArmor profile for bwrap..."
    if sudo tee /etc/apparmor.d/bwrap > /dev/null <<'APPARMOR'
abi <abi/4.0>,
include <tunables/global>

profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,

  include if exists <local/bwrap>
}
APPARMOR
    then
        sudo apparmor_parser -r /etc/apparmor.d/bwrap || warn "Failed to load AppArmor bwrap profile"
    else
        warn "Failed to write AppArmor bwrap profile"
    fi
}

#############################################################################
# Rootless Docker (optional --docker mode)
#############################################################################

# Install Docker CE from Docker's official apt repo, then set it up *rootless*:
# dockerd runs as a `systemd --user` service, with no root daemon and no
# `docker` group. Rootless is deliberate — adding the user to the `docker` group
# grants effective root via the daemon socket, which would undercut this repo's
# hardening posture (managed-settings denies, sandbox, rm/push guards). The
# apt-repo-setup block is reused near-verbatim from Docker's official docs (and
# /opt/linux-setup); only the activation tail differs (rootless setuptool rather
# than the root daemon + `usermod -aG docker` the convenience path uses).
#
# Idempotent: skips the engine install when `docker` is already present (but
# still ensures the rootless + compose runtime deps — uidmap/slirp4netns/
# dbus-user-session/rootless-extras/compose-plugin — which a pre-existing engine
# commonly lacks), and skips the rootless setup when the per-user docker.service
# already exists.
install_docker_rootless() {
    local docker_distro docker_codename
    local need_engine=false need_rootless_deps=false pkg

    command -v docker &>/dev/null || need_engine=true
    # Rootless + compose runtime prereqs: uidmap (newuidmap/newgidmap), slirp4netns
    # (userspace networking), dbus-user-session (user systemd manager),
    # docker-ce-rootless-extras (dockerd-rootless.sh + the setuptool), and
    # docker-compose-plugin (the `docker compose` subcommand the litellm unit's
    # ExecStart/ExecStop invoke). A pre-existing engine often lacks these — without
    # the rootless extras dockerd-rootless-setuptool.sh aborts ("Missing system
    # requirements … apt-get install -y uidmap"), and without the compose plugin
    # the litellm unit's `docker compose up` fails outright (a docker.io host has
    # neither). Ensure them regardless of engine presence.
    for pkg in uidmap slirp4netns dbus-user-session docker-ce-rootless-extras docker-compose-plugin; do
        pkg_installed "$pkg" || { need_rootless_deps=true; break; }
    done

    if [ "$need_engine" = true ] || [ "$need_rootless_deps" = true ]; then
        log "Installing Docker CE / rootless deps (official apt repo)..."

        # Remove conflicting/old packages only when installing the engine fresh
        # (ignore failures — they may be absent); never touch a working engine.
        if [ "$need_engine" = true ]; then
            # Removes change apt state too (they can strand autoremovable deps)
            # — flag Phase 11's autoremove gate directly; the installs below
            # set it via apt_install.
            APT_CHANGED=1
            for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
                sudo apt-get remove -y "$pkg" 2>/dev/null || true
            done
        fi

        # Detect distribution + codename for the Docker repo. Docker only ships
        # repos for specific Debian/Ubuntu releases; fall back to Debian trixie
        # for anything unrecognised (incl. Kali, which tracks Debian testing).
        if [ -f /etc/os-release ]; then
            # shellcheck disable=SC1091
            . /etc/os-release
            if [ "${ID:-}" = "ubuntu" ] || echo "${ID_LIKE:-}" | grep -q "ubuntu"; then
                docker_distro="ubuntu"
                docker_codename="${UBUNTU_CODENAME:-$VERSION_CODENAME}"
                case "$docker_codename" in
                    resolute|questing|noble|jammy) ;;
                    *)
                        warn "Ubuntu codename '$docker_codename' unsupported by Docker — falling back to Debian trixie"
                        docker_distro="debian"; docker_codename="trixie" ;;
                esac
            elif [ "${ID:-}" = "debian" ] || [ "${ID:-}" = "kali" ] || echo "${ID_LIKE:-}" | grep -q "debian"; then
                docker_distro="debian"
                docker_codename="${VERSION_CODENAME:-trixie}"
                case "$docker_codename" in
                    trixie|bookworm|bullseye) ;;
                    *) docker_codename="trixie" ;;   # kali-rolling + anything else -> trixie
                esac
            else
                warn "Unknown distribution '${ID:-?}' — falling back to Debian trixie"
                docker_distro="debian"; docker_codename="trixie"
            fi
        else
            warn "Cannot detect distribution — falling back to Debian trixie"
            docker_distro="debian"; docker_codename="trixie"
        fi

        log "Using Docker repository: ${docker_distro}/${docker_codename}"

        # Docker's official GPG key + apt source. Download as the user via
        # curl_secure (keeps the -q curlrc isolation — a sudo curl would read
        # root's ~/.curlrc, exactly what the helper exists to bypass), then
        # install root-owned.
        local gpg_tmp
        gpg_tmp=$(mktemp)
        # Bare call: a download failure (after retries) aborts under `set -e` —
        # without the key the repo below is unusable anyway.
        download_to_file "https://download.docker.com/linux/${docker_distro}/gpg" "$gpg_tmp" "Docker GPG key"
        sudo install -m 0755 -d /etc/apt/keyrings
        sudo install -m 0644 "$gpg_tmp" /etc/apt/keyrings/docker.asc
        rm -f "$gpg_tmp"
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${docker_distro} ${docker_codename} stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        # Explicit update (not apt_update_once): the Docker repo was just added,
        # so the index must be refreshed even if another phase already did.
        # Re-mark it fresh so a later apt_install this run can skip its update.
        sudo apt-get update
        APT_INDEX_FRESH=1
        if [ "$need_engine" = true ]; then
            apt_install \
                docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin
        fi
        # docker-ce-rootless-extras provides dockerd-rootless-setuptool.sh +
        # dockerd-rootless.sh; uidmap provides newuidmap/newgidmap; slirp4netns
        # provides userspace networking; dbus-user-session lets the user systemd
        # manager start the daemon; docker-compose-plugin provides the
        # `docker compose` subcommand the litellm unit's ExecStart/ExecStop run.
        # Always (re)installed — a pre-existing engine may predate them (rootless
        # setuptool's "Missing system requirements … uidmap" abort, or a docker.io
        # host with no `docker compose` at all); apt is a no-op for any present.
        apt_install \
            docker-ce-rootless-extras uidmap slirp4netns dbus-user-session docker-compose-plugin
    else
        log "Docker + rootless deps already installed — skipping apt install"
    fi

    # Rootless dockerd uses the per-user socket ($XDG_RUNTIME_DIR/docker.sock),
    # which our litellm unit targets via DOCKER_HOST. We deliberately do NOT touch
    # any system-wide docker.service: rootless coexists with it (separate socket),
    # and disabling it here would stop a user's other root-daemon containers.
    # Disabling the system daemon (per Docker's rootless docs) is the user's call,
    # not a silent side effect of this opt-in flag.

    # Rootless prerequisite: unprivileged user namespaces (same kernel feature
    # bwrap/`/sandbox` uses). If AppArmor restricts them and the bwrap profile
    # isn't in place, warn — configure_bwrap_apparmor (Phase 2) usually clears it.
    if apparmor_userns_restricted; then
        warn "Unprivileged user namespaces are AppArmor-restricted — rootless Docker may fail to start."
        warn "  configure_bwrap_apparmor (Phase 2) usually clears this; otherwise see"
        warn "  https://docs.docker.com/engine/security/rootless/#prerequisites"
    fi

    # Set up rootless dockerd as a `systemd --user` service. The setuptool writes
    # ~/.config/systemd/user/docker.service and enables it; guard on that file so
    # re-runs are no-ops.
    if [ -f "${HOME}/.config/systemd/user/docker.service" ]; then
        log "Rootless Docker user service already set up — skipping setuptool"
    else
        log "Setting up rootless Docker (dockerd as systemd --user)..."
        local setuptool
        setuptool="$(command -v dockerd-rootless-setuptool.sh 2>/dev/null || echo /usr/bin/dockerd-rootless-setuptool.sh)"
        if [ -x "$setuptool" ]; then
            # When a rootful Docker daemon is already running its socket is
            # writable, and the setuptool aborts ("Aborting because rootful
            # Docker (/var/run/docker.sock) is running and accessible. Set
            # --force to ignore."). Rootless coexists with it on a separate
            # per-user socket — litellm-docker.service pins DOCKER_HOST to the
            # rootless socket — so pass --force to proceed. Force ONLY when the
            # rootful socket is actually present: on a clean box the bare
            # `install` keeps the setuptool's RootlessKit smoke-test fatal
            # (--force would also downgrade that genuine failure to a warning).
            local install_args=(install)
            if [ -w /var/run/docker.sock ]; then
                log "Rootful Docker detected — installing rootless alongside it (coexists on a separate per-user socket; passing --force)"
                install_args+=(--force)
            fi
            # Needs $XDG_RUNTIME_DIR + a running user systemd (dbus-user-session).
            if ! "$setuptool" "${install_args[@]}"; then
                warn "dockerd-rootless-setuptool.sh install reported an error — rootless Docker may not work (see output above)"
            fi
        else
            warn "dockerd-rootless-setuptool.sh not found — is docker-ce-rootless-extras installed?"
        fi
    fi

    # Enable + start the rootless daemon (linger is enabled just before this
    # phase so it survives logout). Tolerant: the setuptool may already have done both.
    systemctl --user enable docker &>/dev/null || true
    systemctl --user start docker &>/dev/null || warn "Could not start rootless docker.service — start it manually with: systemctl --user start docker"
}

# Ensure the host Postgres accepts password (scram) auth for the `litellm` role
# over its Unix socket. Used by --docker, where the (rootless) LiteLLM container
# connects to the host DB over a bind-mounted socket instead of TCP — no network
# exposure at all. Debian's default pg_hba uses peer auth for `local`
# connections, which rejects the litellm role (the container's mapped UID has no
# matching OS user), so we add a scoped scram rule. Idempotent; inserts the rule
# ABOVE existing `local` rules (pg_hba is first-match-wins) and reloads Postgres.
ensure_pg_socket_scram_rule() {
    local hba_file
    hba_file="$(sudo -u postgres psql -tAc 'SHOW hba_file;' 2>/dev/null | tr -d '[:space:]' || true)"
    if [ -z "$hba_file" ]; then
        warn "Could not determine pg_hba.conf path — skipping socket scram rule (container DB auth may fail)"
        return 0
    fi
    if sudo grep -qE '^[[:space:]]*local[[:space:]]+litellm[[:space:]]+litellm[[:space:]]+scram-sha-256' "$hba_file"; then
        return 0
    fi
    log "Adding scoped pg_hba socket rule (local litellm scram-sha-256)..."
    # Insert at the top so it precedes Debian's default `local all all peer`.
    sudo sed -i '1i local   litellm   litellm   scram-sha-256' "$hba_file"
    sudo systemctl reload postgresql 2>/dev/null || warn "Could not reload Postgres — apply with: sudo systemctl reload postgresql"
}

#############################################################################
# LiteLLM service readiness
#############################################################################

# Poll LiteLLM liveliness endpoint until it responds (max ~90s).
# First boot runs Prisma migrations + may fetch Prisma engine binaries, which
# can take 15–25s on a fresh DB and occasionally longer under load; the prior
# 30s window produced false warnings while LiteLLM was still mid-startup.
# Usage: wait_for_litellm [port]
wait_for_litellm() {
    local port="${1:-4000}"
    local url="http://127.0.0.1:${port}/health/liveliness"
    local max_attempts=90
    local i

    for ((i=1; i<=max_attempts; i++)); do
        if curl -sf --max-time 3 "$url" &>/dev/null; then
            log "LiteLLM is responding on port ${port}"
            return 0
        fi
        sleep 1
    done
    warn "LiteLLM not responding on port ${port} after 90s"
    return 1
}

#############################################################################
# Config file deployment
#############################################################################

# Deploy a config file with permissions. Delegates the content-aware (and
# atomic) write to write_if_changed, so mtime is preserved on no-op runs.
# vs write_if_changed: takes a source PATH and re-asserts mode on every run
# (even no-op ones); use write_if_changed directly when the content comes
# from a pipe or the caller needs the changed/unchanged return status.
# Usage: deploy_config source dest [mode]
deploy_config() {
    local source="$1"
    local dest="$2"
    local mode="${3:-644}"

    # || true: write_if_changed returns 1 on unchanged content, which must not
    # abort the script under `set -e`.
    write_if_changed "$dest" < "$source" || true
    chmod "$mode" "$dest"
}

# Write stdin content to <dest>, leaving mtime untouched if content is unchanged.
# Returns 0 if written (new or modified), 1 if unchanged.
# Usage: <producer> | write_if_changed <dest> [mode]
write_if_changed() {
    local dest="$1"
    local mode="${2:-}"
    local tmp
    tmp=$(mktemp)
    cat > "$tmp"

    if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        return 1
    fi

    mkdir -p "$(dirname "$dest")"
    mv "$tmp" "$dest"
    [ -n "$mode" ] && chmod "$mode" "$dest"
    return 0
}

#############################################################################
# systemd --user service helpers
#############################################################################

# Render a systemd --user service template (via sed), write it under
# ~/.config/systemd/user/, daemon-reload on change. Returns 0 if changed.
# Usage: deploy_user_systemd_service <name> <template> [sed_args...]
deploy_user_systemd_service() {
    local name="$1"
    local template="$2"
    shift 2

    local service_dir="${HOME}/.config/systemd/user"
    local dest="${service_dir}/${name}.service"
    mkdir -p "$service_dir"

    # Render first, then write — piping sed straight into write_if_changed
    # would mask a sed failure (no `set -o pipefail` here): the pipeline's
    # status is write_if_changed's, so a missing/unreadable template or a bad
    # -e expression installs a 0-BYTE unit over a working one and reports
    # "changed", after which the caller daemon-reloads and restarts against it.
    local rendered
    rendered=$(sed "$@" "$template") || {
        error "Failed to render ${template} for ${name}.service — keeping the existing unit"
        return 1
    }
    if [ -z "$rendered" ]; then
        error "Rendered ${name}.service is empty (template: ${template}) — refusing to install it"
        return 1
    fi
    # sed silently passes __TOKEN__ placeholders through when a caller forgets an
    # -e, and systemd would then take them literally (Environment=PATH=__PATH__,
    # an ExecStart that does not exist). Checked before the write, not after, so
    # a bad render never lands on disk.
    if [[ $rendered =~ __[A-Z_]+__ ]]; then
        error "${name}.service has unreplaced template tokens — refusing to install it"
        return 1
    fi

    local changed=0
    printf '%s\n' "$rendered" | write_if_changed "$dest" && changed=1

    if [ "$changed" -eq 1 ]; then
        systemctl --user daemon-reload
        log "${name} service file updated"
    fi
    return $((1 - changed))
}

# Stop a systemd --user service if it's active. No-op otherwise.
stop_user_service_if_active() {
    local name="$1"
    if systemctl --user is-active "$name" &>/dev/null; then
        systemctl --user stop "$name"
        log "${name} service stopped"
    fi
}

# Enable a systemd --user service and restart it only when STALE: when
# <changed> is 1 (something the service consumes was redeployed this run) or
# the unit is not active (`restart` also starts an inactive unit, so one
# branch covers both). An unchanged active service is left running — a no-op
# re-run must not bounce it and drop live connections/sessions. Returns 1 on
# restart failure (explicit `|| return 1`, so the outcome is the same whether
# the caller runs it bare — fatal under `set -e` — or in an `if` condition);
# 0 when restarted or left running.
# Usage: restart_user_service_if_stale <name> <changed 0|1>
restart_user_service_if_stale() {
    local name="$1" changed="$2"
    systemctl --user enable "$name" &>/dev/null || true
    if [ "$changed" = "1" ] || ! systemctl --user is-active "$name" &>/dev/null; then
        # A crash-looped unit latches failed/start-limit-hit; clear it so the
        # restart below is deterministic rather than reliant on the burst
        # window having expired. No-op for units not in a failed state.
        # Trade-off: the restart's exit code no longer flags a crash-looping
        # unit (it starts cleanly and may die moments later) — real liveness
        # needs a probe, e.g. wait_for_litellm after the litellm call site.
        systemctl --user reset-failed "$name" &>/dev/null || true
        systemctl --user restart "$name" || return 1
        log "${name} service (re)started"
    else
        log "${name} unchanged — service left running"
    fi
}

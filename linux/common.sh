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

YES_MODE=${YES_MODE:-false}

# Shell profile files we mirror env-vars into. ~/.profile is sourced by bash
# login shells and (via ~/.zprofile chain on most distros) by zsh login shells;
# non-login shells inherit the env from the parent login shell.
PROFILE_FILES=("${HOME}/.profile")

#############################################################################
# Hardened curl
#############################################################################

# Hardened curl for external HTTPS requests — enforces TLS 1.2+ and HTTPS-only.
# Do NOT use for localhost/health checks (plain HTTP).
curl_secure() {
    curl --proto '=https' --tlsv1.2 "$@"
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
# Profile Management (bash + zsh)
#############################################################################

# Idempotently set an export in every file in PROFILE_FILES (or a custom set
# passed via $3+). Writes "export NAME=\"value\"" with proper escaping.
# Usage: update_profile_export VAR_NAME "value" [profile_file ...]
update_profile_export() {
    local var_name="$1"
    local var_value="$2"
    shift 2
    local files=("$@")
    [ ${#files[@]} -eq 0 ] && files=("${PROFILE_FILES[@]}")

    ensure_managed_bash_profile

    # Escape special characters for shell double-quoted string
    local escaped_value="$var_value"
    escaped_value="${escaped_value//\\/\\\\}"    # \ -> \\
    escaped_value="${escaped_value//\"/\\\"}"    # " -> \"
    escaped_value="${escaped_value//\$/\\\$}"    # $ -> \$
    escaped_value="${escaped_value//\`/\\\`}"    # ` -> \`

    # For sed replacement, also escape & (special in replacement string)
    local sed_value="$escaped_value"
    sed_value="${sed_value//&/\\&}"              # & -> \&

    local profile_file
    for profile_file in "${files[@]}"; do
        [ ! -f "$profile_file" ] && touch "$profile_file"
        if grep -q "^export ${var_name}=" "$profile_file" 2>/dev/null; then
            sed -i "s|^export ${var_name}=.*|export ${var_name}=\"${sed_value}\"|" "$profile_file"
        elif grep -q "^#[[:space:]]*export ${var_name}=" "$profile_file" 2>/dev/null; then
            sed -i "s|^#[[:space:]]*export ${var_name}=.*|export ${var_name}=\"${sed_value}\"|" "$profile_file"
        else
            echo "export ${var_name}=\"${escaped_value}\"" >> "$profile_file"
        fi
    done
}

# Read a previously written value from the first file in PROFILE_FILES that
# contains it. Prints nothing if not present.
# Usage: read_profile_export VAR_NAME [profile_file ...]
read_profile_export() {
    local var_name="$1"
    shift
    local files=("$@")
    [ ${#files[@]} -eq 0 ] && files=("${PROFILE_FILES[@]}")

    local profile_file line
    for profile_file in "${files[@]}"; do
        [ -f "$profile_file" ] || continue
        line=$(grep "^export ${var_name}=" "$profile_file" 2>/dev/null | head -1) || continue
        [ -z "$line" ] && continue
        local value="${line#export ${var_name}=\"}"
        value="${value%\"}"
        # Reverse update_profile_export's escapes in inverse order
        value="${value//\\\`/\`}"
        value="${value//\\\$/\$}"
        value="${value//\\\"/\"}"
        value="${value//\\\\/\\}"
        printf '%s' "$value"
        return 0
    done
}

# Delete any `export VAR_NAME=...` line from each file in PROFILE_FILES (or
# files passed as $2+), and unset the var in the current shell so the rest
# of setup.sh doesn't inherit a value we just decided to scrub.
# Usage: remove_profile_export VAR_NAME [profile_file ...]
remove_profile_export() {
    local var_name="$1"
    shift
    local files=("$@")
    [ ${#files[@]} -eq 0 ] && files=("${PROFILE_FILES[@]}")

    local profile_file
    for profile_file in "${files[@]}"; do
        [ -f "$profile_file" ] || continue
        if grep -q "^export ${var_name}=" "$profile_file" 2>/dev/null; then
            sed -i "/^export ${var_name}=/d" "$profile_file"
        fi
    done

    unset -- "$var_name"
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

    # Build ~/.profile export map in a single pass (reverses the same escapes
    # update_profile_export applies). Used by Passes 2 + 3 below.
    if [ -f "$HOME/.profile" ]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^export[[:space:]]+([A-Z][A-Z0-9_]*)=\"(.*)\"$ ]] || continue
            v="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val//\\\`/\`}"
            val="${val//\\\$/\$}"
            val="${val//\\\"/\"}"
            val="${val//\\\\/\\}"
            profile[$v]="$val"
        done < "$HOME/.profile"
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
        seen[$v]=1
    done
}

# Ensure a PATH line exists in a file (idempotent append). Defaults to ~/.profile.
ensure_path_in_profile() {
    local line="$1"
    local file="${2:-${HOME}/.profile}"

    ensure_managed_bash_profile
    [ ! -f "$file" ] && touch "$file"
    grep -qF "$line" "$file" 2>/dev/null || echo "$line" >> "$file"
}

# Ensure ~/.bash_profile sources ~/.profile so bash login shells pick up our env
# vars. Per bash(1) startup order, login shells read the first of ~/.bash_profile,
# ~/.bash_login, ~/.profile that exists and skip the rest. Tools that drop their
# own ~/.bash_profile (bun, uv, claude installers) would otherwise shadow .profile.
#
# Policy: be a polite co-tenant. If the shim source line is already present,
# leave the file alone — don't wipe installer blocks appended below us. Only
# write when the line is missing (fresh file or someone clobbered the shim);
# preserve any existing content by prepending.
ensure_managed_bash_profile() {
    local shim="${HOME}/.bash_profile"
    local source_line='[ -f ~/.profile ] && . ~/.profile'

    rm -f "${HOME}/.bash_login"

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

#############################################################################
# AppArmor (for bwrap sandbox used by Claude Code)
#############################################################################

# Newer kernels restrict unprivileged user namespaces via AppArmor by default,
# which breaks bwrap sandboxing. Idempotent: only creates profile if absent.
configure_bwrap_apparmor() {
    if command -v apparmor_parser &> /dev/null && \
       [ -d /sys/module/apparmor ] && \
       [ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ] && \
       [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns)" = "1" ] && \
       [ ! -f /etc/apparmor.d/bwrap ]; then
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
    else
        log "AppArmor bwrap profile already configured or not needed"
    fi
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

# Deploy a config file with permissions. Only copies when content differs,
# so mtime is preserved on no-op runs (mode/owner are always re-applied).
# Usage: deploy_config source dest [mode] [owner]
deploy_config() {
    local source="$1"
    local dest="$2"
    local mode="${3:-644}"
    local owner="${4:-${USER}:${USER}}"

    mkdir -p "$(dirname "$dest")"
    if [ ! -f "$dest" ] || ! cmp -s "$source" "$dest"; then
        cp "$source" "$dest"
    fi
    chmod "$mode" "$dest"
    # chown only works if we're root or we own the file already; ignore failures.
    chown "$owner" "$dest" 2>/dev/null || true
}

# Write stdin content to <dest>, leaving mtime untouched if content is unchanged.
# Returns 0 if written (new or modified), 1 if unchanged.
# Usage: <producer> | write_if_changed <dest> [mode] [owner]
write_if_changed() {
    local dest="$1"
    local mode="${2:-}"
    local owner="${3:-}"
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
    [ -n "$owner" ] && chown "$owner" "$dest" 2>/dev/null || true
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

    local changed=0
    sed "$@" "$template" | write_if_changed "$dest" && changed=1

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

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
# Usage: download_and_run <url> <label> [interpreter [installer-args...]]
#        (interpreter defaults to bash)
download_and_run() {
    local url="$1" label="$2" interp="${3:-bash}"
    local tmp
    tmp="$(mktemp)"
    if download_to_file "$url" "$tmp" "$label installer"; then
        # run_bounded: these vendor installers download with bare curl (no
        # timeout) and Claude Code's bootstrap.sh ends by running `claude install` — the CLI
        # whose tty probe / stray-descendant hangs run_bounded exists for.
        run_bounded 1200 180 "$interp" "$tmp" "${@:4}" || warn "$label installer exited non-zero, stalled or timed out"
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

    # For the sed replacement: double every backslash FIRST (sed consumes one
    # level — without this `\"` lands as a bare `"` and a changed value with a
    # quote, $ or backtick writes a broken/expanding line), then escape &
    # (special in the replacement) and | (the s||| delimiter).
    local sed_value="${escaped_value//\\/\\\\}"
    sed_value="${sed_value//&/\\&}"              # & -> \&
    sed_value="${sed_value//|/\\|}"              # | -> \|

    [ ! -f "$PROFILE_FILE" ] && touch "$PROFILE_FILE"
    # Already exactly this line? Skip the sed -i full-file rewrite — with
    # ~36 calls per setup run this keeps a no-op re-run from rewriting
    # ~/.profile dozens of times.
    # One read of every existing export of the name. A no-op only when it is
    # the SOLE line and already right — a duplicate further down (a hand-fix
    # appended at the bottom) is what login shells actually use (last wins),
    # so it must fall through to the sed, which rewrites every matching line.
    local existing
    existing=$(grep "^export ${var_name}=" "$PROFILE_FILE" 2>/dev/null || true)
    if [ "$existing" = "export ${var_name}=\"${escaped_value}\"" ]; then
        return 0
    fi
    if [ -n "$existing" ]; then
        sed -i "s|^export ${var_name}=.*|export ${var_name}=\"${sed_value}\"|" "$PROFILE_FILE"
    elif grep -q "^#[[:space:]]*export ${var_name}=" "$PROFILE_FILE" 2>/dev/null; then
        sed -i "s|^#[[:space:]]*export ${var_name}=.*|export ${var_name}=\"${sed_value}\"|" "$PROFILE_FILE"
    else
        echo "export ${var_name}=\"${escaped_value}\"" >> "$PROFILE_FILE"
    fi
}

# Read NAME's value from a KEY=value env file (systemd EnvironmentFile /
# docker env_file shape — no `export`, no quoting). Prints the value of the
# LAST match, empty when the file or key is absent. Never fails.
# Last, not first: both consumers of these files — systemd EnvironmentFile and
# docker-compose env_file — are last-wins, so a duplicated key (the natural
# shape of a hand-fix appended at the bottom) means the SERVICE ran with the
# last value. Reading the first would hand callers a value the service never
# used — and one caller latches it forever (LITELLM_SALT_KEY, Phase 6).
# Usage: read_env_file_var <file> <NAME>
read_env_file_var() {
    local file="$1" name="$2"
    [ -f "$file" ] || return 0
    grep "^${name}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2-
}

# The path deploy_user_systemd_service writes <name>.service to — one spelling
# for the writer and for callers that test/mask/restore the deployed unit.
# Usage: user_unit_path <name>
user_unit_path() {
    echo "${HOME}/.config/systemd/user/$1.service"
}

# Read a previously written value from PROFILE_FILE. Prints nothing if not
# present.
# Usage: read_profile_export VAR_NAME
read_profile_export() {
    local var_name="$1"
    local line

    [ -f "$PROFILE_FILE" ] || return 0
    # Last match, like the shell that sources the file (and read_env_file_var).
    line=$(grep "^export ${var_name}=" "$PROFILE_FILE" 2>/dev/null | tail -1)
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

# Which env vars count as LiteLLM provider credentials. Coverage (verified by
# grepping get_secret/os.environ.get in upstream LiteLLM):
#   - Pattern: <PROVIDER>_API_{KEY,BASE,VERSION,TOKEN}  (covers ~120 vars)
#   - Plus AWS / GCP / Vertex / watsonx / Azure-AD / OpenAI-org / HF_TOKEN extras
#   - Excludes master key, base URL, internal LITELLM_/UI_ config
# At file scope so is_litellm_provider_var can share them: a second copy would
# drift, and the carry-forward that uses it decides whether a secret survives
# the env-file rewrite.
LITELLM_PROVIDER_PATTERN='^[A-Z][A-Z0-9_]*_(API_KEY|API_BASE|API_VERSION|API_TOKEN)$'
LITELLM_PROVIDER_EXCLUDE='^(ANTHROPIC_AUTH_TOKEN|ANTHROPIC_BASE_URL|LITELLM_|UI_)'
LITELLM_PROVIDER_NAMED=(
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    AWS_REGION_NAME AWS_DEFAULT_REGION AWS_REGION AWS_BEARER_TOKEN_BEDROCK
    GOOGLE_APPLICATION_CREDENTIALS GOOGLE_CLOUD_PROJECT GOOGLE_API_KEY
    VERTEXAI_PROJECT VERTEXAI_LOCATION VERTEX_PROJECT VERTEX_LOCATION
    WATSONX_PROJECT_ID WATSONX_REGION WX_PROJECT_ID WX_REGION
    AZURE_RESOURCE_ENDPOINT AZURE_CLIENT_SECRET AZURE_AD_TOKEN
    OPENAI_ORGANIZATION OPENAI_PROJECT
    HF_TOKEN
)

# The endpoint-shaped subset of the above: provider vars whose VALUE is a URL,
# so a DNS pre-flight knows which ones name a host. Deliberately a separate
# constant rather than derived from the two above — those answer "is this a
# credential", which would drag AWS_ACCESS_KEY_ID into a name lookup. Edit it
# together with them: a new endpoint-shaped var added to LITELLM_PROVIDER_NAMED
# reaches the env file but goes unprobed unless it is added here too.
# Two things are out of reach by construction, not by omission: endpoints LiteLLM
# DERIVES rather than reads (Bedrock from AWS_REGION_NAME, Vertex from
# VERTEX_LOCATION — never URL-shaped), and the api_base of any model added
# through /ui, which STORE_MODEL_IN_DB puts in Postgres. The env file is the
# deterministic source for the endpoints this repo itself configures.
LITELLM_ENDPOINT_PATTERN='^([A-Z][A-Z0-9_]*_API_BASE|AZURE_RESOURCE_ENDPOINT)='

# Resolve <host> the way LiteLLM's transport will, and print HOW it went:
#   ok      resolves
#   v4only  resolves over IPv4 only — the dual-stack lookup fails
#   dead    does not resolve at all
#
# `getent ahosts` is AF_UNSPEC, i.e. the same getaddrinfo call aiohttp's
# ThreadedResolver makes; `ahostsv4` is A-only. Splitting them is the whole
# point of this probe rather than a plain `getent hosts`: the documented failure
# for Azure Foundry endpoints is that the A answer fits inside glibc's 512-byte
# no-EDNS buffer while the AAAA answer truncates, so the dual-stack lookup times
# out (EAI_AGAIN) on a name that resolves perfectly over IPv4. `v4only` IS that
# shape, and its fix differs from `dead`'s — hence three states, not a predicate.
# Printed rather than returned: a non-zero exit would be a finding, not a
# failure, and callers run under `set -e`.
# Under --docker this probes the HOST resolver, which the container inherits
# only when /etc/resolv.conf carries no loopback nameserver (dockerd filters
# those out and substitutes public resolvers).
# Cost against a blackholed resolver is `timeout x attempts x NAMESERVERS`, not
# the per-call `timeout x attempts` the defaults suggest — glibc spends the
# budget on each nameserver in turn (measured: 10s / 20s / 28s for 1 / 2 / 3
# servers at the default timeout:5 attempts:2). Two is the ordinary
# NetworkManager shape, so `timeout 15` is the operative bound here, not a
# belt-and-braces one: it deliberately truncates glibc mid-retry, because a
# lookup that needs more than 15s is already useless to the proxy. Consequence
# to know: a name that would only have resolved via the SECOND nameserver at
# ~16-20s is reported v4only/dead. Worst case is 2 x 15s per endpoint, and only
# on a box that is already failing.
# Usage: endpoint_dns_state <host>
endpoint_dns_state() {
    local host="$1"
    if timeout 15 getent ahosts "$host" &>/dev/null; then
        echo ok
    elif timeout 15 getent ahostsv4 "$host" &>/dev/null; then
        echo v4only
    else
        echo dead
    fi
}

# Hostnames LiteLLM will dial, read from the deployed EnvironmentFile. Values
# are URLs; bare hosts (and host:port) are tolerated. Loopback is skipped — it
# is never a provider. One per line, deduplicated by NAME. The sed mirrors how
# the value is consumed: surrounding quotes are stripped (systemd's
# EnvironmentFile strips them, so a hand-appended `KEY="https://…"` line is
# valid — probing `"https` would cry wolf on exactly the just-repaired box),
# then scheme, path/query, a `user[:pass]@` userinfo prefix and the port.
#
# `tac | awk '!seen[$1]++'` is last-wins on the key — same rule, same reason as
# read_env_file_var above.
# Usage: litellm_endpoint_hosts <env-file>
litellm_endpoint_hosts() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -E "$LITELLM_ENDPOINT_PATTERN" "$file" 2>/dev/null \
        | tac | awk -F= '!seen[$1]++' \
        | cut -d= -f2- \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^(["'"'"'])(.*)\1$/\2/; s#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#[/?].*$##; s#^[^@]*@##; s#:.*$##' \
        | grep -vE '^(localhost|127\.|\[|$)' \
        | sort -u
}

# True when <have> is a strictly newer version than <marker>; false when <have>
# is empty (an unreadable version must not fire a staleness nag). `sort -V` is
# the comparison; wrapping it means the "is a > b" idiom — easy to write
# backwards — is spelled once for every pin that carries a STALE_ABOVE marker.
# Usage: version_newer_than <have> <marker>
version_newer_than() {
    [ -n "$1" ] && [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n1)" != "$2" ]
}

# True when NAME is a var the collector below would emit. Used by setup.sh's
# carry-forward to decide which keys of a previously-deployed env file may be
# preserved when the collector didn't find them.
# Usage: is_litellm_provider_var <NAME>
is_litellm_provider_var() {
    local name="$1"
    [[ "$name" =~ $LITELLM_PROVIDER_EXCLUDE ]] && return 1
    [[ "$name" =~ $LITELLM_PROVIDER_PATTERN ]] && return 0
    [[ " ${LITELLM_PROVIDER_NAMED[*]} " == *" $name "* ]]
}

# Stop exporting the secrets this script holds, so no child inherits them.
# Phase 5 sources .env with `set -a`, which exports EVERY assignment in it —
# provider keys, the LITELLM_* gateway key an overlay writes there, an external
# DATABASE_URL — into every child the script spawns from then on, and Phases
# 7-11 run third-party code (claude-devtools' `pnpm install`/build executes its
# whole dependency tree's lifecycle scripts; the `claude plugin` network calls).
# `export -n`, not `unset`: the shell variables stay readable here (Phase 7 reads
# DATABASE_URL, the end banner ANTHROPIC_AUTH_TOKEN); only inheritance stops.
# Covers: every name .env assigned (ENV_FILE_VARS, recorded by Phase 5), every
# exported provider var by collect_litellm_provider_vars' own test (also catches
# keys exported by the caller rather than .env), and the gateway key names.
# Call only after Phase 6 — collect_litellm_provider_vars reads `compgen -e`.
# Usage: unexport_secrets
unexport_secrets() {
    local v
    while IFS= read -r v; do
        is_litellm_provider_var "$v" && export -n "$v"
    done < <(compgen -e)
    export -n "${ENV_FILE_VARS[@]}" ANTHROPIC_AUTH_TOKEN LITELLM_API_KEY LITELLM_MASTER_KEY 2>/dev/null || true
}

# Machine-readable outcome of the last setup.sh run, for callers that run it as
# a subprocess (the ct-* overlays). Its exit status alone can't carry this: the
# claude-is-running skip exits 0 by design, exactly like a full run, so a caller
# would otherwise have to re-implement the session detection (and race it).
# Fixed path — a contract, not XDG-relative: callers run us via sudo, where
# XDG_STATE_HOME is reset. KEY=value lines; callers must PARSE it, never source
# it — the file is user-writable and an overlay reads it as root. Keys:
#   outcome = running | skipped-session | complete   (`running` left behind = the
#             run aborted part-way)
#   litellm = none | ready | not-ready | client-broken   (Phase 7's verdict;
#             client-broken = deliberately left stopped, never restart it)
# Written via a temp file in the SAME directory, so the mv is a real rename and
# a reader never sees a partial file. Never fatal.
# Usage: write_run_status <outcome> [litellm-state]
RUN_STATUS_FILE="${HOME}/.local/state/claude-litellm/run-status"
write_run_status() {
    mkdir -p "${RUN_STATUS_FILE%/*}" 2>/dev/null \
        && printf 'outcome=%s\nlitellm=%s\n' "$1" "${2:-none}" > "${RUN_STATUS_FILE}.tmp" \
        && mv -f "${RUN_STATUS_FILE}.tmp" "$RUN_STATUS_FILE" || true
}

# Emit `KEY=VALUE` lines for every LiteLLM-relevant provider env var found in
# the current shell environment or ~/.profile — intended to be concatenated
# into the LiteLLM systemd EnvironmentFile. Priority when a var is set in more
# than one place: current env > ~/.profile.
collect_litellm_provider_vars() {
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
        [[ "$v" =~ $LITELLM_PROVIDER_PATTERN ]] || continue
        [[ "$v" =~ $LITELLM_PROVIDER_EXCLUDE ]] && continue
        val="${!v}"
        [ -z "$val" ] && continue
        printf '%s=%s\n' "$v" "$val"
        seen[$v]=1
    done < <(compgen -e)

    # Pass 2: named non-pattern vars (current env, fallback to profile map)
    for v in "${LITELLM_PROVIDER_NAMED[@]}"; do
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
        [[ "$v" =~ $LITELLM_PROVIDER_PATTERN ]] || continue
        [[ "$v" =~ $LITELLM_PROVIDER_EXCLUDE ]] && continue
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

# Run a command unattended with every way it can hang bounded. Prints the
# command's combined stdout+stderr AFTER it exits and returns its status
# (124 = budget exceeded, 125 = stalled, 137 = force-killed). Notices go to
# stderr, so `out=$(run_bounded …)` captures only the command's output.
#  - stdin </dev/null and output to a FILE, never a pipe: a `| cat`/`$(…)`
#    reader waits for EOF until EVERY holder of the write end has exited, so a
#    descendant the command leaves behind hangs the caller forever, past
#    `timeout` (it signals only its own process group). This is what hung
#    `claude update` on 2026-11-13; it also keeps claude's tty capability probe
#    (OSC 11/DA1 queries answered on stdin) from firing.
#  - `timeout -k 15 <budget>`: hard ceiling with SIGKILL escalation.
#  - <stall> > 0 adds a watchdog for long network steps: the process group's
#    read+write byte counters (/proc/<pid>/io) are sampled every 5s; flat for
#    <stall> seconds → ended early (125) with the process group printed, and a
#    heartbeat every 30s reports elapsed time and MB moved (no tty → no
#    progress bar of their own). Unreadable counters disable only the stall
#    check. <stall> 0 runs in the foreground with no poll at all — the right
#    choice for short calls, which then return the moment the command exits.
# Usage: run_bounded <budget-secs> <stall-secs|0> <command> [args…]
run_bounded() {
    local budget="$1" stall="$2"; shift 2
    local out pid rc=0 start=$SECONDS last_change=$SECONDS beat=$SECONDS
    local io last=-1 base=-1 p k v tick done_pid
    out="$(mktemp)"
    if [ "$stall" -le 0 ]; then
        timeout -k 15 "$budget" "$@" </dev/null >"$out" 2>&1 || rc=$?
    else
        timeout -k 15 "$budget" "$@" </dev/null >"$out" 2>&1 &
        pid=$!
        while :; do
            # Wake on whichever ends first — the command or the 5s sample tick —
            # so the command's exit is seen at once, not on the next tick.
            sleep 5 & tick=$!
            wait -n -p done_pid "$pid" "$tick" 2>/dev/null; rc=$?
            if [ "${done_pid:-}" = "$pid" ]; then
                kill "$tick" 2>/dev/null; wait "$tick" 2>/dev/null
                break
            fi
            rc=0 io=0
            for p in $(pgrep -g "$pid" 2>/dev/null); do
                while read -r k v; do
                    case "$k" in rchar:|wchar:) io=$((io + v)) ;; esac
                done 2>/dev/null < "/proc/$p/io" || true
            done
            # Counters unreadable (hardened /proc): no watchdog is possible —
            # fall back to the plain ceiling instead of polling for nothing.
            if [ "$io" -eq 0 ] && [ "$base" -lt 0 ]; then
                wait "$pid" || rc=$?
                break
            fi
            [ "$base" -lt 0 ] && base=$io
            [ "$io" != "$last" ] && last_change=$SECONDS
            last=$io
            if [ $((SECONDS - last_change)) -ge "$stall" ]; then
                warn "$1 ${2:-}: no I/O for ${stall}s — ending it. Process group at that moment:" >&2
                ps -o pid,stat,etimes,wchan:24,args -g "$pid" >&2 2>/dev/null || true
                kill -TERM "$pid" 2>/dev/null || true
                wait "$pid" 2>/dev/null || true
                rc=125
                break
            fi
            if [ $((SECONDS - beat)) -ge 30 ]; then
                beat=$SECONDS
                log "  $1 ${2:-} still running — $((SECONDS - start))s, $(( (io - base) / 1048576 )) MB moved (ceiling ${budget}s)" >&2
            fi
        done
    fi
    cat "$out"
    rm -f "$out"
    return "$rc"
}


# Where the claude launcher is: on PATH, else where the installer puts it (a
# fresh install in this same run may not be on PATH yet).
claude_launcher() { command -v claude 2>/dev/null || echo "${HOME}/.local/bin/claude"; }
# Same resolution the binary uses (env-paths): XDG_DATA_HOME, else ~/.local/share.
claude_versions_dir() { echo "${XDG_DATA_HOME:-${HOME}/.local/share}/claude/versions"; }

# The live Claude Code binary — the launcher symlink's target inside the versions
# dir, the only layout Claude Code itself manages (and so the only one in which
# a version file may be pruned, verified or removed). Prints it; returns 1 when
# the launcher is not a symlink, 2 when it resolves outside the versions dir.
# Usage: target=$(claude_active_binary)
claude_active_binary() {
    local launcher target
    launcher="$(claude_launcher)"
    [ -L "$launcher" ] || return 1
    target="$(readlink -f "$launcher" 2>/dev/null)" || return 2
    [[ "$target" == "$(claude_versions_dir)"/* ]] || return 2
    printf '%s\n' "$target"
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
    local versions_dir target running f size removed=0 freed=0

    versions_dir="$(claude_versions_dir)"
    [ -d "$versions_dir" ] || return 0

    local rc=0
    target="$(claude_active_binary)" || rc=$?
    case "$rc" in
        0) ;;
        1) warn "Claude Code launcher $(claude_launcher) is not a symlink — its built-in version cleanup is disabled and updates cannot replace it; remove the file and re-run 'claude install stable'"
           return 0 ;;
        *) warn "Claude Code launcher $(claude_launcher) resolves outside ${versions_dir} — skipping version prune"
           return 0 ;;
    esac

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

# Check the active Claude Code binary against Anthropic's release manifest —
# the one test that tells a corrupt install from an environment problem when the
# CLI will not start. Observed 2026-11-13 on a ct-dfir-llm VM: versions/2.1.311
# had the right size but the wrong sha256, and every invocation (--version
# included) parked forever in a futex right after dynamic linking — so
# `claude update` could not heal it either; only a reinstall can.
# Returns 0 = matches, 1 = mismatch, 2 = cannot tell (no managed launcher —
# see claude_active_binary —, unknown arch, manifest unreachable).
# Usage: claude_binary_verify
claude_binary_verify() {
    local target ver platform want have
    target="$(claude_active_binary)" || return 2
    ver="${target##*/}"
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 2
    # Platform key as Anthropic's own bootstrap.sh derives it.
    case "$(uname -m)" in
        x86_64|amd64) platform=linux-x64 ;;
        aarch64|arm64) platform=linux-arm64 ;;
        *) return 2 ;;
    esac
    ldd --version 2>&1 | grep -qi musl && platform+="-musl"
    want="$(curl_secure -fsS --max-time 30 \
        "https://downloads.claude.ai/claude-code-releases/${ver}/manifest.json" 2>/dev/null \
        | jq -r --arg p "$platform" '.platforms[$p].checksum // empty' 2>/dev/null)"
    [ -n "$want" ] || return 2
    have="$(sha256sum "$target" 2>/dev/null)"; have="${have%% *}"
    [ -n "$have" ] || return 2
    [ "$have" = "$want" ]
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

# Read a single server setting from the live cluster through pg_wrapper's
# psql, which routes to the same cluster the rest of the Phase 6 bootstrap
# talks to. Prints nothing on failure (the pipeline's status is tr's, so a
# psql failure never trips `set -e`) — callers own their fallback policy.
# Usage: pg_setting <name>
pg_setting() {
    sudo -u postgres psql -tAc "SHOW $1;" 2>/dev/null | tr -d '[:space:]'
}

# Ensure the host Postgres accepts password (scram) auth for the `litellm` role
# over its Unix socket. Used by every local-Postgres install: Phase 6 connects
# LiteLLM over the socket in both runtimes (native since the socket switch;
# --docker from the start, via the bind-mounted socket dir). Debian's default
# pg_hba uses peer auth for `local` connections, which rejects the litellm role
# either way — natively the service runs as the deploy user (no `litellm` OS
# account), and under --docker the container's mapped UID has no matching OS
# user at all — so we add a scoped scram rule. Idempotent; inserts the rule
# ABOVE existing `local` rules (pg_hba is first-match-wins) and reloads Postgres.
# The other half of the invariant — the role's stored verifier must itself be
# scram, or this rule can never match — is owned by Phase 6's role branch,
# which (re)hashes the password under `password_encryption = 'scram-sha-256'`.
# The reload is best-effort (warn on failure): the idempotence check below
# tests the *file*, not the postmaster's loaded config, so Phase 6's preflight
# owns re-asserting the loaded state (pg_reload_conf + retry on probe failure).
ensure_pg_socket_scram_rule() {
    local hba_file
    hba_file="$(pg_setting hba_file)"
    if [ -z "$hba_file" ]; then
        warn "Could not determine pg_hba.conf path — skipping socket scram rule (litellm DB auth may fail)"
        return 0
    fi
    if sudo grep -qE '^[[:space:]]*local[[:space:]]+litellm[[:space:]]+litellm[[:space:]]+scram-sha-256' "$hba_file"; then
        return 0
    fi
    log "Adding scoped pg_hba socket rule (local litellm scram-sha-256)..."
    # Insert at the top so it precedes Debian's default `local all all peer`.
    sudo sed -i '1i local   litellm   litellm   scram-sha-256' "$hba_file"
    # Reload via the server itself (pg_reload_conf = SIGHUP), NOT `systemctl
    # reload postgresql`: that targets the umbrella unit, which is inactive on
    # exactly the boxes this repo configures — Phase 6 enables the *instance*
    # unit (postgresql@<ver>-main) directly because Kali's umbrella is a
    # preset-disabled /bin/true shell (see the Phase 6 comment) — so the
    # systemctl form fails with "not active, cannot reload" on every native
    # install. The server is definitionally up here (it just answered SHOW
    # hba_file), so a failure is anomalous; warn with a command that works.
    sudo -u postgres psql -qAtc 'SELECT pg_reload_conf()' >/dev/null 2>&1 \
        || warn "Could not reload Postgres — apply with: sudo -u postgres psql -c 'SELECT pg_reload_conf()'"
}

# Heal a C-library collation-version mismatch (PostgreSQL ≥15). Postgres records
# the libc/ICU collation version each database was created under
# (pg_database.datcollversion) and, once the OS version moves on, WARNs on every
# connection — "database "postgres" has a collation version mismatch … created
# using collation version 2.42, but the operating system provides version 2.43"
# (observed 2026-11-13 on Kali after glibc 2.42 → 2.43; a rolling distro hits
# this on every glibc bump, a stable one essentially never). The warning is
# about correctness, not noise: a btree index over default-collation text may
# be ordered by the OLD rules, so lookups through it can silently miss rows
# until it is rebuilt. Upstream's remedy, verbatim from the HINT: rebuild, then
# `ALTER DATABASE … REFRESH COLLATION VERSION`.
#
# Scope is the databases this setup owns or connects to, nothing else:
#   - litellm   — ours; its text indexes (keys, model names) are the ones at risk
#   - postgres  — the maintenance DB every bootstrap `sudo -u postgres psql`
#                 lands on (the source of the two warnings in Phase 6's output)
#   - template1 — PG15+ CREATE DATABASE *refuses* to copy a template whose
#                 version mismatches ("template database "template1" has a
#                 collation version mismatch"), so on a box whose cluster
#                 predates the libc bump a FRESH litellm install would fail
#                 at createdb — the hard failure hiding behind the warning
# Any other mismatched database (e.g. Kali's metasploit `msf`) belongs to
# another tool and gets a warning with the fix, never a silent REINDEX —
# rebuilding someone else's indexes is the user's call. template0 is skipped
# by construction: initdb stores its datcollversion as NULL.
#
# REINDEX DATABASE and the refresh run in ONE psql session connected to the
# target (REINDEX DATABASE can only name the current database), as separate
# -c statements (each its own transaction; REINDEX DATABASE cannot run inside
# one), with ON_ERROR_STOP so a failed rebuild never records the new version —
# a nagging warning beats silencing it over possibly mis-ordered indexes.
# PG16+ REINDEX DATABASE skips system catalogs, which is correct here: catalog
# text columns use the "C" collation, which no libc upgrade can change. Phase 6
# runs this while litellm is stopped (Phase 4a's stop; start deferred to
# Phase 7), so the rebuild's per-table locks contend with nothing; under
# --docker the container may be up, and REINDEX simply queues its writes for
# the seconds a small table takes. Called before any other Phase 6 query so
# the rest of the phase runs warning-free. Never fatal: always returns 0.
# Usage: pg_refresh_collation_versions
pg_refresh_collation_versions() {
    local rows db err others=()
    # stderr dropped deliberately: this very connection (to `postgres`) is one
    # that emits the mismatch WARNING. It doubles as the version gate:
    # datcollversion / pg_database_collation_actual_version() are PG15+, so on
    # an older server (no per-database version, never this warning) the query
    # errors and `|| return 0` reads that as nothing to do. `<>` (not IS
    # DISTINCT FROM) so a NULL actual version — a provider without versioning —
    # never counts as drift.
    rows="$(sudo -u postgres psql -XtAc "SELECT datname FROM pg_database
        WHERE datallowconn AND datcollversion IS NOT NULL
          AND datcollversion <> pg_database_collation_actual_version(oid)
        ORDER BY datname" 2>/dev/null)" || return 0
    [ -n "$rows" ] || return 0
    while IFS= read -r db; do
        case "$db" in
            litellm|postgres|template1)
                log "Postgres database '${db}': collation version changed (C library upgrade) — rebuilding indexes + refreshing the recorded version..."
                # Fixed identifiers only (the case arm above), so the inline
                # quoting is safe. stderr captured, not shown: a successful run
                # still prints the connect-time WARNING and the refresh NOTICE.
                if err="$(sudo -u postgres psql -Xq -v ON_ERROR_STOP=1 -d "$db" \
                        -c "REINDEX DATABASE \"${db}\"" \
                        -c "ALTER DATABASE \"${db}\" REFRESH COLLATION VERSION" 2>&1 >/dev/null)"; then
                    log "Postgres database '${db}': collation version refreshed"
                else
                    warn "Postgres database '${db}': collation refresh failed — left as-is (the mismatch warning will continue). Last error: $(printf '%s\n' "$err" | grep -E 'ERROR|FATAL' | tail -n1)"
                fi
                ;;
            *) others+=("$db") ;;
        esac
    done <<< "$rows"
    if [ "${#others[@]}" -gt 0 ]; then
        warn "Postgres database(s) not managed by this setup report a collation version mismatch (C library upgrade): ${others[*]} — left untouched. Fix each with: sudo -u postgres psql -d <db> -c 'REINDEX DATABASE <db>' -c 'ALTER DATABASE <db> REFRESH COLLATION VERSION'"
    fi
    return 0
}

# Probe a Postgres connection URL (Phase 6's socket preflight). The URL must
# NOT embed the password — psql's argv is world-readable in /proc/*/cmdline —
# so it is passed separately and rides PGPASSWORD. Always call in a
# conditional so a failed probe never trips `set -e`.
# Usage: pg_url_works <url-without-password> <password>
pg_url_works() {
    PGPASSWORD="$2" PGCONNECT_TIMEOUT=5 psql "$1" -tAc 'SELECT 1' &>/dev/null
}

#############################################################################
# LiteLLM service readiness
#############################################################################

# Poll LiteLLM's readiness endpoint until it responds.
# Typical starts answer in 15–25s (uvicorn + a no-op `prisma migrate deploy`
# sync); LITELLM_WAIT_SHORT covers those. The caller passes
# LITELLM_WAIT_LONG ONLY for a start that actually happened this run (Phase 7
# — in native mode that is every run, since Phase 4a stops the unit for the
# venv/toolchain work and never restarts it itself) because such a start can
# legitimately run long: the schema sync is bounded at ≤4 attempts × 60s
# hard-killed + 5–15s sleeps (litellm_proxy_extras/utils.py::_setup_database_v2,
# see CLAUDE.md > Troubleshooting, "prisma in the process list") ≈ 300s. Under
# the v2 resolver an UNRECOVERABLE sync does NOT fall through to a bind — it
# raises and proxy_cli.py exits 2 — so a genuinely broken sync ends this wait
# via the crash-loop bail-out below, not by timing out. On
# a CPU-starved VM every arc step (bare `prisma` spawn, migrate, the proxy
# import) stretches further (observed 2026-08-20: a converging start ran past
# the old 360s budget while sharing ~1 core with the rest of the run, and the
# resulting "not responding" warning invited an overlay recovery restart that
# killed it mid-arc and paid the arc again). 900s is safe to grant because
# the wait no longer sits out the whole budget blind: it bails as soon as the
# unit parks `failed` (start-limit) or is demonstrably crash-looping
# (NRestarts grew ≥3 while waiting — reset-failed zeroes the counter before
# the initial restart, so growth during the wait is all crash-loop). Where
# `systemctl --user` itself is unavailable, both probes degrade to no-ops and
# only the wall-clock bound applies. An unchanged already-running service
# keeps the short budget so a genuinely broken box doesn't stall a no-op
# re-run. The budget is wall-clock (SECONDS deadline), not an iteration count
# — curl's --max-time 3 would otherwise stretch each iteration to 4s on a
# hung connect and quietly quadruple it. Cadence: 1s while a fast start is
# still plausible, 5s once the wait is clearly in the bounded-sync regime
# (the fast path is unchanged — returns the second the probe passes); a
# progress note at 60s on the long budget tells the operator the
# long-but-bounded case is expected.
# Usage: wait_for_litellm [port] [max_wait_seconds]
LITELLM_WAIT_SHORT=90
LITELLM_WAIT_LONG=900
wait_for_litellm() {
    local port="${1:-4000}"
    local budget="${2:-$LITELLM_WAIT_SHORT}"
    # /health/readiness, NOT /health/liveliness: liveliness returns "I'm alive!"
    # unconditionally, so it answers 200 with the DB unreachable and setup.sh
    # would report success on a box whose every authenticated request then 500s.
    # readiness is unauthenticated too and reports `db` — what upstream's own
    # charts use to mean "ready". A 503 keeps the loop waiting, correct while
    # Postgres is still coming up behind the unit's pg_isready gate. Note its
    # 15s server-side cache covers the CONNECTED path only; a not-yet-connected
    # probe runs a real DB health check (and a reconnect attempt), so keep the
    # poll cadence from getting tight — that is the one window we poll hardest.
    local url="http://127.0.0.1:${port}/health/readiness"
    local hint="check: journalctl --user -u litellm -n 100"
    local start="$SECONDS" elapsed=0 interval=1 noted=0
    local probe unit_state restarts_now restarts_start=""

    while :; do
        if curl -sf --max-time 3 "$url" &>/dev/null; then
            log "LiteLLM is responding on port ${port}"
            return 0
        fi
        elapsed=$((SECONDS - start))
        [ "$elapsed" -ge "$budget" ] && break
        # Early bail-outs — the big budget may only be spent on a start that
        # is still progressing, never sat out against a dead or looping unit.
        # One `systemctl show` answers both probes (ActiveState carries what
        # is-active would say); the NRestarts baseline is taken on the first
        # failed readiness probe, so a box that answers immediately never
        # spawns systemctl at all. An empty/garbled read (no user bus) makes
        # both probes no-ops and leaves only the wall-clock bound.
        # Parsed as KEY=VALUE, not by position: `systemctl show` emits properties
        # in bus/vtable order, not the order requested, and --value strips the
        # names that would make the parse order-independent. Today's ordering
        # happens to match; a flip would silently turn both bail-outs into dead
        # code and sit out the whole 900s budget against a dead unit. Matched
        # with BASH_REMATCH rather than `sed`: this runs every iteration of a
        # loop that can last 900s, and those forks would be stolen from the very
        # single-core start arc the loop is waiting on.
        probe="$(systemctl --user show -p ActiveState -p NRestarts litellm 2>/dev/null || true)"
        unit_state=""; restarts_now=""
        [[ $probe =~ (^|$'\n')ActiveState=([^$'\n']*) ]] && unit_state="${BASH_REMATCH[2]}"
        [[ $probe =~ (^|$'\n')NRestarts=([^$'\n']*) ]] && restarts_now="${BASH_REMATCH[2]}"
        if [ "$unit_state" = "failed" ]; then
            warn "litellm parked failed (start-limit) after ${elapsed}s — not waiting out the ${budget}s budget; ${hint}"
            return 1
        fi
        if [[ "$restarts_now" =~ ^[0-9]+$ ]]; then
            [ -n "$restarts_start" ] || restarts_start="$restarts_now"
            if [ $((restarts_now - restarts_start)) -ge 3 ]; then
                # Restart growth has two shapes under the v2 migration resolver
                # and the journal tells them apart: a DRIFTED LEDGER (a box
                # provisioned in the brief --use_prisma_db_push era) heals ≤3
                # migrations per start, exits 2 and comes back — dozens of
                # cycles, far past any budget, but converging, and an overlay
                # recovery restart would only reset it (see CLAUDE.md,
                # "A `prisma migrate deploy` process"). Its fingerprint is
                # "marking applied"/"creating baseline" lines — note each such
                # cycle ALSO ends in "Database migration cannot proceed" (the
                # 4-attempt budget raising), so that line alone does not mean
                # fatal; fatal is "cannot proceed" WITHOUT the healing lines
                # (or an import traceback). One journalctl spawn, at bail-out
                # time only.
                local jtail
                jtail="$(journalctl --user -u litellm -n 400 --no-pager -o cat 2>/dev/null || true)"
                if [[ $jtail == *"failed idempotently"* || $jtail == *"marking applied"* || $jtail == *"creating baseline"* ]]; then
                    warn "litellm restarted $((restarts_now - restarts_start))x while waiting (${elapsed}s in) but the journal shows the startup schema sync CONVERGING (migrations being marked applied, ~3 per start; each cycle's trailing 'Database migration cannot proceed' is the 4-attempt budget, not a fatal error) — expected on a box with a drifted migrations ledger, not a crash loop. Leave the unit alone; it comes up by itself once the ledger is caught up. Not waiting out the ${budget}s budget; ${hint}"
                else
                    warn "litellm crash-looping ($((restarts_now - restarts_start)) restarts while waiting, ${elapsed}s in) — not waiting out the ${budget}s budget; ${hint} (look for 'Database migration cannot proceed' = fatal, needs a human)"
                fi
                return 1
            fi
        fi
        if [ "$noted" = 0 ] && [ "$budget" -gt "$LITELLM_WAIT_SHORT" ] && [ "$elapsed" -ge 60 ]; then
            log "LiteLLM still starting — the startup schema sync (prisma migrate deploy) is bounded at ~5 min worst case, longer on a CPU-starved box; waiting up to ${budget}s total"
            noted=1
        fi
        [ "$elapsed" -ge 10 ] && interval=5
        sleep "$interval"
    done
    warn "LiteLLM not responding on port ${port} after ${budget}s; ${hint}"
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

# Render a __TOKEN__ template through sed and install it, refusing anything that
# would land broken on disk. Returns 0 only when the destination changed (1 for
# unchanged AND for a refused render, so a caller that treats non-zero as
# "nothing to do" keeps the previous good copy either way).
#
# Rendering into a variable first is the whole point: piping sed straight into
# write_if_changed masks a sed failure (there is no `set -o pipefail` here), so
# the pipeline's status is write_if_changed's and a missing template or a bad
# -e expression installs a 0-BYTE file over a working one while reporting
# "changed". The token check catches the other half — sed silently passes
# __PLACEHOLDER__ through when a caller forgets an -e, and every consumer here
# takes it literally (systemd runs `Environment=PATH=__PATH__`; a compose file
# pulls image `:__LITELLM_IMAGE_TAG__`).
# A leftover template token is a DELIMITED `__UPPER__` word — not any
# `__UPPER__` substring. The distinction matters for managed-settings.json:
# Claude Code's MCP permission rules are spelled `mcp__<server>__<tool>`, and
# a server name in upper case (`mcp__JIRA__search_issues`) contains
# `__JIRA__` glued to alphanumerics on both sides. Every token this repo
# renders (`__PORT__`, `__REPO_DIR__`, …) is preceded/followed by a
# non-alphanumeric (`=`, `:`, `"`, `/`, line edge), so requiring that edge
# keeps the refusal for real leftovers and stops it false-positiving on a
# policy entry — which would silently keep a STALE root-owned policy file
# in place on every run. Shared by render_template_if_changed and the
# Phase 8a sudo-install path, which restates the guard in grep form.
TEMPLATE_TOKEN_RE='(^|[^A-Za-z0-9])__[A-Z][A-Z0-9_]*__([^A-Za-z0-9]|$)'

# Usage: render_template_if_changed <template> <dest> <label> [sed_args...]
# The validated render on its own, for callers that cannot use write_if_changed
# to place the result (the managed-settings deploy needs `sudo install`). Prints
# the rendered template on success; errors and returns 1 on any of the three
# refusals. Keeping this separate from the placement is what lets every consumer
# share ONE guard policy — a guard added here reaches the root-owned policy file
# too, which is where a bad render is most severe.
# Usage: render_template_or_fail <template> <label> [sed_args...]
render_template_or_fail() {
    local template="$1" label="$2"
    shift 2

    local rendered
    rendered=$(sed "$@" "$template") || {
        error "Failed to render ${template} for ${label} — keeping the existing copy"
        return 1
    }
    if [ -z "$rendered" ]; then
        error "Rendered ${label} is empty (template: ${template}) — refusing to install it"
        return 1
    fi
    if [[ $rendered =~ $TEMPLATE_TOKEN_RE ]]; then
        error "${label} has unreplaced template tokens — refusing to install it"
        return 1
    fi
    printf '%s\n' "$rendered"
}

render_template_if_changed() {
    local template="$1" dest="$2" label="$3"
    shift 3

    local rendered
    rendered="$(render_template_or_fail "$template" "$label" "$@")" || return 1
    printf '%s\n' "$rendered" | write_if_changed "$dest"
}

# Render a systemd --user service template (via sed), write it under
# ~/.config/systemd/user/, daemon-reload on change. Returns 0 if changed
# (1 for unchanged AND for a render render_template_if_changed refused, so the
# caller keeps the previous good unit either way).
# Usage: deploy_user_systemd_service <name> <template> [sed_args...]
deploy_user_systemd_service() {
    local name="$1"
    local template="$2"
    shift 2

    local dest
    dest="$(user_unit_path "$name")"

    render_template_if_changed "$template" "$dest" "${name}.service" "$@" || return 1

    systemctl --user daemon-reload
    log "${name} service file updated"
    return 0
}

# Stop a systemd --user service, unconditionally. NEVER gate a stop on
# `is-active`: that probe is non-zero for `activating (auto-restart)`
# — where a crash-looping unit spends ~10s of every ~11s cycle — and for
# `failed` (start-limit parked), so an activity gate skips the stop on exactly
# the units that most need stopping, leaving their queued auto-restart live
# (observed 2026-08-19: a wedged unit restarting into Phase 4a's venv rebuild
# straight through the gated stop). `systemctl stop` on an inactive or unknown
# unit is a free no-op that also cancels any queued restart. Always returns 0:
# setup.sh calls this bare under `set -e` on paths where the unit is routinely
# already inactive.
stop_user_service() {
    local name="$1"
    systemctl --user stop "$name" &>/dev/null || true
    log "${name} stop issued (no-op if it wasn't running)"
    return 0
}

# Hold / release MANUAL starts of a systemd --user unit across a maintenance
# window (Phase 4a's venv rebuild). `systemctl --user mask --runtime` is the
# obvious primitive and DOES NOT WORK for a unit deployed under
# ~/.config/systemd/user: in the USER manager's load path that directory
# outranks $XDG_RUNTIME_DIR/systemd/user (`systemd-analyze --user unit-paths`
# — the reverse of the system manager's /run-over-/etc order), so the runtime
# /dev/null link is shadowed by the real unit and a `start` goes straight
# through; a persistent mask is refused outright ("File … already exists"),
# and `--force` would REPLACE the deployed unit with the /dev/null link. A
# runtime DROP-IN has neither problem: drop-ins from every load-path directory
# are merged into the unit regardless of where its fragment lives. So the hold
# is `RefuseManualStart=yes` in $XDG_RUNTIME_DIR/systemd/user/<name>.service.d/
# — `systemctl start`/`restart` then fail with "Operation refused, unit … may
# be requested by dependency only" (nothing depends on these units), `stop`
# stays allowed, and the unit file is untouched. Restart= auto-restarts are
# not manual and are NOT held — the caller's unconditional stop cancels those.
# Lives in /run, so a hard-killed run is healed by reboot; release is an
# explicit rm + daemon-reload. Both are free no-ops on a name with no unit yet
# (fresh install: the drop-in waits for the unit Phase 7 deploys and is
# released before that) and on a box with no user bus. Release also removes a
# stale runtime MASK link an older setup.sh revision left for the same unit.
# Usage: hold_user_service_starts <name> / release_user_service_starts <name>
user_service_hold_dir() {
    echo "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/systemd/user/$1.service.d"
}
hold_user_service_starts() {
    local name="$1" dir
    dir="$(user_service_hold_dir "$name")"
    mkdir -p "$dir" 2>/dev/null || return 0
    printf '[Unit]\n# claude-litellm setup.sh: starts held for the duration of a maintenance window.\n# Safe to delete (then `systemctl --user daemon-reload`) if setup.sh is no longer running.\nRefuseManualStart=yes\n' \
        > "$dir/50-setup-hold.conf" 2>/dev/null || return 0
    systemctl --user daemon-reload &>/dev/null || true
    return 0
}
release_user_service_starts() {
    local name="$1" dir changed=0
    dir="$(user_service_hold_dir "$name")"
    if [ -e "$dir/50-setup-hold.conf" ]; then
        rm -f "$dir/50-setup-hold.conf"
        rmdir "$dir" 2>/dev/null || true
        changed=1
    fi
    # Transitional: a runtime mask link from the previous mechanism (inert
    # while the persistent unit exists, but it would mask a fresh install).
    if [ -L "${dir%.d}" ] && [ "$(readlink "${dir%.d}")" = /dev/null ]; then
        rm -f "${dir%.d}"
        changed=1
    fi
    [ "$changed" = 1 ] && systemctl --user daemon-reload &>/dev/null
    return 0
}

# Enable a systemd --user service and restart it only when STALE: when
# <changed> is 1 (something the service consumes was redeployed this run) or
# the unit is not active (`restart` also starts an inactive unit, so one
# branch covers both). An unchanged active service is left running — a no-op
# re-run must not bounce it and drop live connections/sessions. Returns 1 on
# restart failure (explicit `|| return 1`, so the outcome is the same whether
# the caller runs it bare — fatal under `set -e` — or in an `if` condition);
# 0 when restarted or left running. Reports which of those it did in
# USER_SERVICE_RESTARTED (1 = (re)started, 0 = left running) so callers that
# need the fact — e.g. Phase 7 sizing wait_for_litellm's budget — read the
# action taken instead of re-deriving this function's staleness predicate at
# the call site (two spellings of one policy silently desync).
# Usage: restart_user_service_if_stale <name> <changed 0|1>
restart_user_service_if_stale() {
    local name="$1" changed="$2"
    USER_SERVICE_RESTARTED=0
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
        USER_SERVICE_RESTARTED=1
        log "${name} service (re)started"
    else
        log "${name} unchanged — service left running"
    fi
}

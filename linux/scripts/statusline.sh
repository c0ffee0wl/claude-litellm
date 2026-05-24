#!/bin/bash
# Two-line statusline.
# Line 1: (user@host)-[cwd] | session duration [(sandboxed)]
# Line 2: [Model] [bar] PCT% (CTX_SIZE) | (mode-specific suffix)
#
# A red "(sandboxed)" tag trails the duration when the bubblewrap sandbox is
# effectively enabled. Claude Code does not expose sandbox state to statuslines
# (no JSON field, no env var — anthropics/claude-code#30772), so this is
# best-effort: the effective sandbox.enabled is read across the settings
# precedence chain AND bwrap must be present (else CC silently runs unsandboxed).
#
# Mode is detected via ANTHROPIC_BASE_URL:
#   DIRECT  — empty or non-local: show 5h/7d rate-limit budgets (Claude.ai
#            Pro/Max), each with a reset countdown from rate_limits.*.resets_at
#   LITELLM — 127.0.0.1:4000: show progress bar + model + ctx %, with the
#            upstream model (e.g. gpt-5.4) appended after an arrow when
#            available via LiteLLM's /model/info endpoint, plus month-to-date
#            gateway spend (labelled "/mo") from LiteLLM's /global/spend
#   OTHER   — other local proxy (CCR etc.): hide line 2 like the upstream script

# Errors must never leak to Claude Code's UI
exec 2>/dev/null

input=$(cat)

# Inside a bubblewrap sandbox the inherited $USER/$HOSTNAME may reflect the
# outer environment, while `id`/`hostname` return the sandboxed values. Always
# fork to get the live identity that matches what the user sees in their shell.
user=$(id -un)
host=$(hostname -s)

# Single jq fork. -e exits non-zero on null/false top-level; invalid JSON also fails.
# @tsv keeps field boundaries intact even with embedded tabs/newlines.
# Every field defaults to a NON-empty sentinel ("-"): tab is IFS-whitespace, so
# `read` collapses runs of tabs — an empty middle field (e.g. an absent
# five_hour while seven_day is present) would otherwise shift every later field
# left. "-" fails the numeric regexes downstream, so it reads as "absent".
# project_dir falls back to current_dir here (it's the /sandbox toggle location).
tsv_output=$(printf '%s' "$input" | jq -er '[
    .workspace.current_dir // "~",
    .workspace.project_dir // .workspace.current_dir // "~",
    .cost.total_duration_ms // 0,
    .model.display_name // "unknown",
    .model.id // "-",
    (.context_window.used_percentage // 0 | floor),
    .context_window.context_window_size // 200000,
    .rate_limits.five_hour.used_percentage // "-",
    .rate_limits.seven_day.used_percentage // "-",
    .rate_limits.five_hour.resets_at // "-",
    .rate_limits.seven_day.resets_at // "-",
    .session_id // "-"
] | @tsv' 2>/dev/null)

if [ -z "$tsv_output" ]; then
    printf "\033[1;32m(%s@%s)\033[0m" "$user" "$host"
    exit 0
fi

IFS=$'\t' read -r cwd proj_dir DURATION_MS MODEL MODEL_ID PCT CTX_SIZE FIVE_H WEEK FIVE_H_RESET WEEK_RESET SESSION_ID <<<"$tsv_output"

# Sanitize numerics — defend against any surprise output from jq
[[ "$DURATION_MS" =~ ^[0-9]+$ ]] || DURATION_MS=0
[[ "$PCT" =~ ^[0-9]+$ ]] || PCT=0
[[ "$CTX_SIZE" =~ ^[0-9]+$ ]] || CTX_SIZE=200000
# "-" is the absent-field sentinel from the jq @tsv above; restore empty for
# fields whose emptiness carries meaning.
[ "$MODEL_ID" = "-" ] && MODEL_ID=""

prompt_symbol="@"
if [ "$EUID" -eq 0 ]; then
    prompt_color="94"
    info_color="31"
else
    prompt_color="32"
    info_color="34"
fi

# Best-effort sandbox detection. Resolve the effective sandbox.enabled across
# the settings precedence chain (highest first), taking the first file that
# *defines* the key — so an explicit higher-layer `false` wins over a lower
# `true`. The try/catch always emits exactly one token, mapping an absent or
# malformed sandbox block to "unset" (keep looking) and keeping an explicit
# `false` distinct from absent.
# Project-level files are read from project_dir (the launch dir, where /sandbox
# persists its runtime toggle) — NOT current_dir, which drifts as the session
# cd's into subdirs. proj_dir already falls back to current_dir in the jq above.
SANDBOX_ON=""
sb_root="$proj_dir"
for sb_file in /etc/claude-code/managed-settings.json \
               "$sb_root/.claude/settings.local.json" \
               "$sb_root/.claude/settings.json" \
               "$HOME/.claude/settings.json"; do
    [ -r "$sb_file" ] || continue
    sb_val=$(jq -r 'try (.sandbox.enabled) catch null | if .==true then "true" elif .==false then "false" else "unset" end' "$sb_file" 2>/dev/null)
    case "$sb_val" in
        true) SANDBOX_ON=1; break ;;
        false) SANDBOX_ON=""; break ;;
    esac
done
# Require bubblewrap present, else CC silently runs unsandboxed (e.g. --router-only).
SANDBOXED=""
[ -n "$SANDBOX_ON" ] && command -v bwrap >/dev/null 2>&1 && SANDBOXED=1

# Mode detection
MODE="DIRECT"
if [[ "$ANTHROPIC_BASE_URL" =~ ^https?://(127\.0\.0\.1|localhost):4000(/|$) ]]; then
    MODE="LITELLM"
elif [[ "$ANTHROPIC_BASE_URL" =~ ^https?://(127\.0\.0\.1|localhost)(:|/) ]]; then
    MODE="OTHER"
fi

# Resolve the LiteLLM master key on demand, memoised — shared by /model/info
# and /global/spend. Sources, in order: env (when Claude Code passes it
# through), ~/.profile (where update_profile_export writes it),
# ~/.config/litellm/env (the systemd EnvironmentFile, mode 600). Lazy + memoised
# so the sed forks happen only on a cache miss, at most once per render.
TOKEN=""; TOKEN_RESOLVED=""
resolve_token() {
    [ -n "$TOKEN_RESOLVED" ] && return
    TOKEN_RESOLVED=1
    TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"
    if [ -z "$TOKEN" ] && [ -r "$HOME/.profile" ]; then
        TOKEN=$(sed -n 's/^export ANTHROPIC_AUTH_TOKEN="\(.*\)"$/\1/p' "$HOME/.profile" | head -1)
    fi
    if [ -z "$TOKEN" ] && [ -r "$HOME/.config/litellm/env" ]; then
        TOKEN=$(sed -n 's/^LITELLM_MASTER_KEY=//p' "$HOME/.config/litellm/env" | head -1)
        # EnvironmentFile values may be quoted — strip a matched surrounding pair.
        TOKEN="${TOKEN%\"}"; TOKEN="${TOKEN#\"}"
        TOKEN="${TOKEN%\'}"; TOKEN="${TOKEN#\'}"
    fi
}

# LiteLLM lookups (cached). Falls through silently on any error — statusline
# must never block or error.
UPSTREAM_MODEL=""
SPEND=""
if [ "$MODE" = "LITELLM" ]; then
    CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}"

    # Resolve upstream model via /model/info (cached 5min).
    if [ -n "$MODEL_ID" ]; then
        CACHE_FILE="${CACHE_DIR}/claude-litellm-modelinfo-${EUID}.json"
        if [ ! -s "$CACHE_FILE" ] || [ -z "$(find "$CACHE_FILE" -mmin -5 2>/dev/null)" ]; then
            resolve_token
            if [ -n "$TOKEN" ]; then
                TMP_FILE="${CACHE_FILE}.$$.tmp"
                curl -sf --max-time 1 \
                    -H "Authorization: Bearer $TOKEN" \
                    "${ANTHROPIC_BASE_URL%/}/model/info" \
                    -o "$TMP_FILE" 2>/dev/null \
                    && mv "$TMP_FILE" "$CACHE_FILE" 2>/dev/null
                rm -f "$TMP_FILE" 2>/dev/null
            fi
        fi
        if [ -s "$CACHE_FILE" ]; then
            # Match against model_name (public alias) OR model_info.id (internal
            # uuid); Claude Code's .model.id is usually the alias but be defensive.
            UPSTREAM_MODEL=$(jq -r --arg id "$MODEL_ID" \
                '[.data[]? | select(.model_name == $id or (.model_info.id // "") == $id) | .litellm_params.model][0] // empty' \
                "$CACHE_FILE" 2>/dev/null)
            UPSTREAM_MODEL="${UPSTREAM_MODEL#*/}"
        fi
    fi

    # Month-to-date gateway spend via /global/spend (cached 1min). The master
    # key is proxy admin, so user_api_key_auth passes; returns {"spend": <usd>}.
    SPEND_CACHE="${CACHE_DIR}/claude-litellm-spend-${EUID}.json"
    if [ ! -s "$SPEND_CACHE" ] || [ -z "$(find "$SPEND_CACHE" -mmin -1 2>/dev/null)" ]; then
        resolve_token
        if [ -n "$TOKEN" ]; then
            TMP_FILE="${SPEND_CACHE}.$$.tmp"
            curl -sf --max-time 1 \
                -H "Authorization: Bearer $TOKEN" \
                "${ANTHROPIC_BASE_URL%/}/global/spend" \
                -o "$TMP_FILE" 2>/dev/null \
                && mv "$TMP_FILE" "$SPEND_CACHE" 2>/dev/null
            rm -f "$TMP_FILE" 2>/dev/null
        fi
    fi
    [ -s "$SPEND_CACHE" ] && SPEND=$(jq -r '.spend // empty' "$SPEND_CACHE" 2>/dev/null)
fi

# Line 1: identity + directory + (duration, only once the first turn completes)
printf "\033[1;${info_color}m(%s%s%s\033[0;${prompt_color}m)-[\033[0;1m%s\033[0;${prompt_color}m]" \
    "$user" "$prompt_symbol" "$host" "$cwd"
if [ "$DURATION_MS" -gt 0 ]; then
    printf " | \033[0;${info_color}m%sm %ss" \
        "$((DURATION_MS / 60000))" "$(((DURATION_MS % 60000) / 1000))"
fi
[ -n "$SANDBOXED" ] && printf " \033[31m(sandboxed)\033[0m"
printf "\033[0m\n"

# Line 2 is suppressed for unknown local proxies (data shape is unclear)
[ "$MODE" = "OTHER" ] && exit 0

GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'

# Compact "time remaining" from an epoch-seconds timestamp; prints nothing on
# invalid input, "now" once the window has elapsed.
fmt_reset() {
    local at="$1" now diff d h m
    [[ "$at" =~ ^[0-9]+$ ]] || return
    now=$(date +%s); diff=$((at - now)); (( diff <= 0 )) && { printf 'now'; return; }
    d=$((diff/86400)); h=$(((diff%86400)/3600)); m=$(((diff%3600)/60))
    if   (( d > 0 )); then printf '%dd%dh' "$d" "$h"
    elif (( h > 0 )); then printf '%dh%dm' "$h" "$m"
    else printf '%dm' "$m"; fi
}

# Color-coded progress bar
if [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

FILLED=$((PCT / 10)); EMPTY=$((10 - FILLED))
BAR=""
[ "$FILLED" -gt 0 ] && printf -v FILL "%${FILLED}s" && BAR="${FILL// /█}"
[ "$EMPTY" -gt 0 ] && printf -v PAD "%${EMPTY}s" && BAR="${BAR}${PAD// /░}"

# Context window size label (handles 400K, 1M, 1.5M etc.)
if (( CTX_SIZE >= 1000000 )); then
    if (( CTX_SIZE % 1000000 == 0 )); then
        CTX_LABEL="$((CTX_SIZE / 1000000))M"
    else
        tenths=$((CTX_SIZE / 100000))
        CTX_LABEL="${tenths:0:-1}.${tenths: -1}M"
    fi
else
    CTX_LABEL="$((CTX_SIZE / 1000))K"
fi

MODEL_LABEL="$MODEL"
# Skip the arrow when upstream is just the model_id with its provider prefix
# stripped (e.g. MODEL_ID=azure/gpt-5.4, UPSTREAM_MODEL=gpt-5.4) — that's the
# alias-free config where Public Name == LiteLLM model, so the arrow is noise.
[ -n "$UPSTREAM_MODEL" ] && [ "$UPSTREAM_MODEL" != "$MODEL_ID" ] && [ "$UPSTREAM_MODEL" != "${MODEL_ID#*/}" ] && MODEL_LABEL="${MODEL} → ${UPSTREAM_MODEL}"
LINE2="${GREEN}[${MODEL_LABEL}] ${BAR_COLOR}${BAR}${GREEN} ${PCT}% (${CTX_LABEL})"

# Mode-specific suffix. LC_ALL=C pins awk/printf to '.' decimals regardless of
# the inherited locale; the regex requires a well-formed number (no multi-dot).
SUFFIX=""
if [ "$MODE" = "DIRECT" ]; then
    # Anthropic Pro/Max: 5h and 7d budget percentages, each with a reset countdown
    if [[ "$FIVE_H" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        r=$(fmt_reset "$FIVE_H_RESET"); SUFFIX="5h: $(LC_ALL=C printf '%.0f' "$FIVE_H")%${r:+ ($r)}"
    fi
    if [[ "$WEEK" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        r=$(fmt_reset "$WEEK_RESET"); SUFFIX="${SUFFIX:+$SUFFIX, }7d: $(LC_ALL=C printf '%.0f' "$WEEK")%${r:+ ($r)}"
    fi
elif [ "$MODE" = "LITELLM" ] && [[ "$SPEND" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    # Month-to-date gateway spend, explicitly labelled "/mo" so it can't be
    # mistaken for session cost; awk for the float compare
    if   LC_ALL=C awk "BEGIN{exit !($SPEND>=0.01)}"; then SUFFIX="$(LC_ALL=C printf '$%.2f/mo' "$SPEND")"
    elif LC_ALL=C awk "BEGIN{exit !($SPEND>0)}";    then SUFFIX="$(LC_ALL=C printf '$%.4f/mo' "$SPEND")"; fi
fi

[ -n "$SUFFIX" ] && LINE2="${LINE2} | ${SUFFIX}"

echo -e "${LINE2}${RESET}"

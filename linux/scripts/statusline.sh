#!/bin/bash
# Two-line statusline.
# Line 1: (user@host)-[cwd] | session duration
# Line 2: [Model] [bar] PCT% (CTX_SIZE) | (mode-specific suffix)
#
# Mode is detected via ANTHROPIC_BASE_URL:
#   DIRECT  — empty or non-local: show 5h/7d rate-limit budgets (Claude.ai Pro/Max)
#   LITELLM — 127.0.0.1:4000: show progress bar + model + ctx %, with the
#            upstream model (e.g. gpt-5.4) appended after an arrow when
#            available via LiteLLM's /model/info endpoint
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
tsv_output=$(printf '%s' "$input" | jq -er '[
    .workspace.current_dir // "~",
    .cost.total_duration_ms // 0,
    .model.display_name // "unknown",
    .model.id // "",
    (.context_window.used_percentage // 0 | floor),
    .context_window.context_window_size // 200000,
    .rate_limits.five_hour.used_percentage // "",
    .rate_limits.seven_day.used_percentage // "",
    .session_id // ""
] | @tsv' 2>/dev/null)

if [ -z "$tsv_output" ]; then
    printf "\033[1;32m(%s@%s)\033[0m" "$user" "$host"
    exit 0
fi

IFS=$'\t' read -r cwd DURATION_MS MODEL MODEL_ID PCT CTX_SIZE FIVE_H WEEK SESSION_ID <<<"$tsv_output"

# Sanitize numerics — defend against any surprise output from jq
[[ "$DURATION_MS" =~ ^[0-9]+$ ]] || DURATION_MS=0
[[ "$PCT" =~ ^[0-9]+$ ]] || PCT=0
[[ "$CTX_SIZE" =~ ^[0-9]+$ ]] || CTX_SIZE=200000

prompt_symbol="@"
if [ "$EUID" -eq 0 ]; then
    prompt_color="94"
    info_color="31"
else
    prompt_color="32"
    info_color="34"
fi

# Mode detection
MODE="DIRECT"
if [[ "$ANTHROPIC_BASE_URL" =~ ^https?://(127\.0\.0\.1|localhost):4000(/|$) ]]; then
    MODE="LITELLM"
elif [[ "$ANTHROPIC_BASE_URL" =~ ^https?://(127\.0\.0\.1|localhost)(:|/) ]]; then
    MODE="OTHER"
fi

# Resolve upstream model via LiteLLM's /model/info (cached 5min).
# Falls through silently on any error — statusline must never block or error.
UPSTREAM_MODEL=""
if [ "$MODE" = "LITELLM" ] && [ -n "$MODEL_ID" ]; then
    CACHE_DIR="${XDG_RUNTIME_DIR:-/tmp}"
    CACHE_FILE="${CACHE_DIR}/claude-litellm-modelinfo-${EUID}.json"

    if [ ! -s "$CACHE_FILE" ] || [ -z "$(find "$CACHE_FILE" -mmin -5 2>/dev/null)" ]; then
        # Token sources, in order: env (when Claude Code passes it through),
        # ~/.profile (where update_profile_export writes it), ~/.config/litellm/env
        # (the systemd EnvironmentFile, mode 600, where master key always lands).
        TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"
        if [ -z "$TOKEN" ] && [ -r "$HOME/.profile" ]; then
            TOKEN=$(sed -n 's/^export ANTHROPIC_AUTH_TOKEN="\(.*\)"$/\1/p' "$HOME/.profile" | head -1)
        fi
        if [ -z "$TOKEN" ] && [ -r "$HOME/.config/litellm/env" ]; then
            TOKEN=$(sed -n 's/^LITELLM_MASTER_KEY=\(.*\)$/\1/p' "$HOME/.config/litellm/env" | head -1)
        fi
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
        # Match against model_name (public alias) OR model_info.id (internal uuid);
        # Claude Code's .model.id is usually the alias but be defensive.
        UPSTREAM_MODEL=$(jq -r --arg id "$MODEL_ID" \
            '[.data[]? | select(.model_name == $id or (.model_info.id // "") == $id) | .litellm_params.model][0] // empty' \
            "$CACHE_FILE" 2>/dev/null)
        UPSTREAM_MODEL="${UPSTREAM_MODEL#*/}"
    fi
fi

# Line 1: identity + directory + (duration, only once the first turn completes)
printf "\033[1;${info_color}m(%s%s%s\033[0;${prompt_color}m)-[\033[0;1m%s\033[0;${prompt_color}m]" \
    "$user" "$prompt_symbol" "$host" "$cwd"
if [ "$DURATION_MS" -gt 0 ]; then
    printf " | \033[0;${info_color}m%sm %ss" \
        "$((DURATION_MS / 60000))" "$(((DURATION_MS % 60000) / 1000))"
fi
printf "\033[0m\n"

# Line 2 is suppressed for unknown local proxies (data shape is unclear)
[ "$MODE" = "OTHER" ] && exit 0

GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'

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

# Mode-specific suffix
SUFFIX=""
if [ "$MODE" = "DIRECT" ]; then
    # Anthropic Pro/Max: 5h and 7d budget percentages
    [[ "$FIVE_H" =~ ^[0-9.]+$ ]] && SUFFIX="5h: $(printf '%.0f' "$FIVE_H")%"
    [[ "$WEEK" =~ ^[0-9.]+$ ]] && SUFFIX="${SUFFIX:+$SUFFIX }7d: $(printf '%.0f' "$WEEK")%"
fi

[ -n "$SUFFIX" ] && LINE2="${LINE2} | ${SUFFIX}"

echo -e "${LINE2}${RESET}"

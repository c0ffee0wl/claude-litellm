#!/bin/bash
#
# add-sandbox-block.sh [--disabled]
#
# Add the canonical sandbox block from configs/claude-settings.json to an
# existing ~/.claude/settings.json that lacks one, preserving every other key
# (idempotent `//=` add-if-missing merge). setup.sh never auto-modifies the
# Claude-Code-owned settings file (Phase 8c); its end-of-setup banner points
# here so adding the block stays an explicit user action.
#
#   --disabled   seed the block with enabled:false (the --router-only default).
#                The credential/network floor stays pre-configured — set
#                sandbox.enabled:true later to activate it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../common.sh"

TEMPLATE="$SCRIPT_DIR/../configs/claude-settings.json"
SETTINGS="${HOME}/.claude/settings.json"

SANDBOX_ENABLED=true
case "${1:-}" in
    --disabled) SANDBOX_ENABLED=false ;;
    "") ;;
    *) error "unknown option: $1 (usage: $0 [--disabled])"; exit 2 ;;
esac

if [ ! -f "$SETTINGS" ]; then
    error "$SETTINGS not found — run linux/setup.sh first (it deploys the full template on a fresh install)."
    exit 1
fi

# Exit early when the block already exists: the merge below would be a no-op
# semantically, but jq re-formats the whole document, and a CC-owned file must
# not be rewritten just to normalize whitespace.
if jq -e 'has("sandbox")' "$SETTINGS" >/dev/null; then
    log "$SETTINGS already has a sandbox block — nothing to do."
    exit 0
fi

# Capture jq's output before touching the file: with `set -e`, a jq failure
# aborts here instead of feeding empty output into the write (same guard as
# setup.sh Phase 8c).
MERGED=$(jq --argjson enabled "$SANDBOX_ENABLED" --slurpfile tpl "$TEMPLATE" \
    '.sandbox //= ($tpl[0].sandbox | .enabled = $enabled)' "$SETTINGS")

if printf '%s\n' "$MERGED" | write_if_changed "$SETTINGS" 644 "${USER}:${USER}"; then
    log "sandbox block added (enabled: $SANDBOX_ENABLED) — restart Claude Code to pick it up."
else
    log "$SETTINGS unchanged."
fi

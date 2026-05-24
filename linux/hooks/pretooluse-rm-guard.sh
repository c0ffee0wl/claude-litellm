#!/bin/bash
# PreToolUse hook: block recursive force deletes from Bash.
# Input (stdin JSON): { "tool_input": { "command": "..." }, ... }
# Exit 2 = block tool invocation, message to stderr shown to user.
#
# Retained as a repo-owned, root-enforced, bypass-surviving floor: PreToolUse
# hooks fire even under --dangerously-skip-permissions (where the
# permissions.deny[] rm rules are skipped and nah's filesystem_delete=context
# likely allows non-sensitive deletes), so this exit-2 guard is the only layer
# that hard-blocks recursive-force deletes in that mode. Complements (does not
# replace) the deny rules and the nah plugin. See CLAUDE.md > "Action-aware
# permission layer".

CMD=$(jq -r '.tool_input.command')

if echo "$CMD" | grep -qiE '(^|;[[:space:]]*|&&[[:space:]]*|[|][|][[:space:]]*|[|][[:space:]]*)rm[[:space:]]' \
    && echo "$CMD" | grep -qiE '(^|[[:space:]])-[a-zA-Z]*[rR]|--recursive' \
    && echo "$CMD" | grep -qiE '(^|[[:space:]])-[a-zA-Z]*[fF]|--force'; then
    echo 'BLOCKED: recursive force delete is not allowed' >&2
    exit 2
fi

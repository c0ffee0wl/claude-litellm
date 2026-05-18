#!/bin/bash
# PreToolUse hook: block direct push to main/master from Bash.
# Input (stdin JSON): { "tool_input": { "command": "..." }, ... }
# Exit 2 = block tool invocation, message to stderr shown to user.

CMD=$(jq -r '.tool_input.command')

if echo "$CMD" | grep -qE 'git[[:space:]]+push.*(main|master)'; then
    echo 'BLOCKED: Use feature branches, not direct push to main' >&2
    exit 2
fi

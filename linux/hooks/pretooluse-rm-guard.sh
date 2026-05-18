#!/bin/bash
# PreToolUse hook: block recursive force deletes from Bash.
# Input (stdin JSON): { "tool_input": { "command": "..." }, ... }
# Exit 2 = block tool invocation, message to stderr shown to user.

CMD=$(jq -r '.tool_input.command')

if echo "$CMD" | grep -qiE '(^|;[[:space:]]*|&&[[:space:]]*|[|][|][[:space:]]*|[|][[:space:]]*)rm[[:space:]]' \
    && echo "$CMD" | grep -qiE '(^|[[:space:]])-[a-zA-Z]*[rR]|--recursive' \
    && echo "$CMD" | grep -qiE '(^|[[:space:]])-[a-zA-Z]*[fF]|--force'; then
    echo 'BLOCKED: recursive force delete is not allowed' >&2
    exit 2
fi

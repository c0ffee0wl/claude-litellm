#!/bin/bash
# PreToolUse hook: block recursive force deletes from Bash.
# Input (stdin JSON): { "tool_input": { "command": "..." }, ... }
# Exit 2 = block tool invocation, message to stderr shown to user.
#
# Retained as a repo-owned, root-enforced, bypass-surviving floor: PreToolUse
# hooks fire even under --dangerously-skip-permissions (where the
# permissions.deny[] rm rules are skipped and nah's filesystem_delete=context
# likely allows non-sensitive deletes). Scope is deliberately narrow: it blocks
# only DIRECT top-level recursive-force `rm` (-rf / -Rf / --recursive --force,
# any flag order/case). It does NOT catch wrapped forms — `sudo rm -rf`,
# `sh -c`/`bash -c '… rm -rf'`, `xargs rm`, `find -delete` — those are nah's job
# (action/content scan) and ultimately the bubblewrap sandbox's. Complements
# (does not replace) the deny rules and the nah plugin. See CLAUDE.md >
# "Action-aware permission layer".

CMD=$(jq -r '.tool_input.command')

if echo "$CMD" | grep -qiE '(^|;[[:space:]]*|&&[[:space:]]*|[|][|][[:space:]]*|[|][[:space:]]*)rm[[:space:]]' \
    && echo "$CMD" | grep -qiE '(^|[[:space:]])-[a-zA-Z]*[rR]|--recursive' \
    && echo "$CMD" | grep -qiE '(^|[[:space:]])-[a-zA-Z]*[fF]|--force'; then
    echo 'BLOCKED: recursive force delete is not allowed' >&2
    exit 2
fi

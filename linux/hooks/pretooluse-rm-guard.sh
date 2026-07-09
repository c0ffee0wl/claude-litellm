#!/bin/bash
# PreToolUse hook: block recursive force deletes from Bash.
# Input (stdin JSON): { "tool_input": { "command": "..." }, ... }
# Exit 2 = block tool invocation, message to stderr shown to user.
#
# Retained as a repo-owned, root-enforced, bypass-surviving floor: PreToolUse
# hooks fire even under --dangerously-skip-permissions (where the
# permissions.deny[] rm rules are skipped and nah's filesystem_delete=context
# likely allows non-sensitive deletes). Scope is deliberately narrow: it blocks
# only DIRECT recursive-force `rm` (-rf / -Rf / --recursive --force, any flag
# order/case) at a command position — including subshell/command-substitution
# positions like `(rm -rf x)` and `$(rm -rf x)`. It does NOT catch argument-
# wrapped forms — `sudo rm -rf`, `sh -c`/`bash -c '… rm -rf'`, `xargs rm`,
# `find -delete` — those are the job of the action-aware plugin layer (nah,
# installed in the same modes that deploy this hook) and ultimately the
# bubblewrap sandbox. Complements (does not replace) both. See CLAUDE.md >
# "Action-aware permission layer".
#
# Matching is per command SEGMENT: the input is split on the shell separators
# `;` `&` `|` `(` `)` backtick and newline (covering `&&`/`||`/`$(` for free),
# and both flags must appear in the same segment that starts with `rm`. This
# keeps `rm file.txt && cp -rf a b` allowed (the -rf belongs to cp) while
# catching `sleep 1 & rm -rf x` and leading-whitespace forms the old
# whole-string greps mishandled. Splitting also fires inside quoted strings
# (`echo "x; rm -rf /"`) — accepted: a string matcher can't parse shell, and
# over-blocking is the safe side here.

CMD=$(jq -r '.tool_input.command // empty')

# Fast path: no "rm" substring at all -> nothing to scan (this hook runs on
# every Bash tool call).
[[ "$CMD" == *rm* ]] || exit 0

seps=';&|()`'
while IFS= read -r seg; do
    [[ "$seg" =~ ^[[:space:]]*rm([[:space:]]|$) ]] || continue
    if [[ "$seg" =~ (^|[[:space:]])-[a-zA-Z]*[rR]|--recursive ]] \
        && [[ "$seg" =~ (^|[[:space:]])-[a-zA-Z]*[fF]|--force ]]; then
        echo 'BLOCKED: recursive force delete is not allowed' >&2
        exit 2
    fi
done <<<"${CMD//[$seps]/$'\n'}"
exit 0

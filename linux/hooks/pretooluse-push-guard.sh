#!/bin/bash
# PreToolUse hook: block direct push to main/master from Bash.
# Input (stdin JSON): { "tool_input": { "command": "..." }, "cwd": "...", ... }
# Exit 2 = block tool invocation, message to stderr shown to user.
#
# The command is split into segments on the shell separators `;` `&` `|` `(`
# `)` backtick and newline (same idiom as the sibling rm-guard, covering
# `&&`/`||`/`$(` for free), and each segment gets three stages — so
# `git push origin feature/domain-fix` is no longer blocked for containing the
# substring "main", while `cd /x && git push origin main`,
# `git -C /repo push origin main`, and a bare `git push` on main are caught:
#   1. The segment must be a git push invocation. Global options (-C <path>,
#      -c k=v, --flags) may sit between `git` and `push` — but not arbitrary
#      words, so `git commit -m 'push to main'` stays allowed.
#   2. Token walk after `push`: block when a token names main/master exactly —
#      bare branch, refs/heads path, or refspec destination (`x:main`, incl.
#      the `:main` deletion form).
#   3. Bare push (no explicit refspec = fewer than 2 non-flag tokens): git
#      pushes the CURRENT branch, so resolve it from the hook's cwd (honouring
#      a -C value) and block on main/master. Outside a git repo the resolution
#      fails -> allow.
# Accepted residuals of string matching: quoted content (`echo "git push
# main"`) still blocks, and a push to main via `HEAD` with
# push.default=upstream tracking a differently-named remote branch isn't
# resolved.

set -f
input=$(</dev/stdin)
CMD=$(jq -r '.tool_input.command // empty' <<<"$input")

block() { echo "BLOCKED: $1" >&2; exit 2; }

seps=';&|()`'
while IFS= read -r seg; do
    # Stage 1: `git`, optional global options (each `-opt`, optionally
    # followed by one value word), then `push`.
    [[ "$seg" =~ (^|[^[:alnum:]_./-])git([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push([[:space:]]|$) ]] || continue

    # Stage 2: segments contain no separators, so a plain word walk suffices.
    # Track a -C value seen before `push` for stage 3.
    seen_push=0 nonflag=0 c_dir="" prev=""
    for tok in $seg; do
        tok="${tok//[\"\']/}"
        if [ "$seen_push" = 0 ]; then
            [ "$prev" = "-C" ] && c_dir="$tok"
            prev="$tok"
            [ "$tok" = "push" ] && seen_push=1
            continue
        fi
        case "$tok" in
            -*|'') ;;
            main|master|refs/heads/main|refs/heads/master|*:main|*:master|*:refs/heads/main|*:refs/heads/master)
                block "Use feature branches, not direct push to ${tok##*:}" ;;
            *) nonflag=$((nonflag + 1)) ;;
        esac
    done

    # Stage 3: bare push (at most a remote named, no refspec) pushes the
    # current branch — resolve it from the repo the command targets.
    if [ "$seen_push" = 1 ] && [ "$nonflag" -lt 2 ]; then
        # cwd is only needed here — don't pay the jq fork on the common path.
        cwd=$(jq -r '.cwd // empty' <<<"$input")
        branch=$(git -C "${cwd:-$PWD}" ${c_dir:+-C "$c_dir"} symbolic-ref --quiet --short HEAD 2>/dev/null)
        case "$branch" in
            main|master) block "bare 'git push' while on $branch — use a feature branch" ;;
        esac
    fi
done <<<"${CMD//[$seps]/$'\n'}"
exit 0

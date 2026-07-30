#!/bin/bash
# PreToolUse hook: single guard for the Bash tool — blocks (a) recursive force
# deletes and (b) direct pushes to main/master. Merged from the former
# pretooluse-rm-guard.sh + pretooluse-push-guard.sh so every Bash tool call
# pays ONE bash+jq spawn instead of two, and the security-critical
# segment-split idiom exists exactly once.
# Input (stdin JSON): { "tool_input": { "command": "..." }, "cwd": "...", ... }
# Exit 2 = block tool invocation, message to stderr shown to user.
#
# Retained as a repo-owned, root-enforced, bypass-surviving floor: PreToolUse
# hooks fire even under --dangerously-skip-permissions (where the
# permissions.deny[] rules are skipped and nah's filesystem_delete=context
# likely allows non-sensitive deletes). Scope is deliberately narrow — the
# action-aware plugin layer (nah) and ultimately the bubblewrap sandbox own
# the wrapper-evasion cases (`sudo rm -rf`, `sh -c '… rm -rf'`, `xargs rm`,
# `find -delete`). Complements (does not replace) both. See CLAUDE.md >
# "Action-aware permission layer".
#
# Matching is per command SEGMENT: the input is split on the shell separators
# `;` `&` `|` `(` `)` backtick and newline (covering `&&`/`||`/`$(` for free),
# so `rm file.txt && cp -rf a b` stays allowed (the -rf belongs to cp) and
# `git commit -m 'push to main'` stays allowed, while `sleep 1 & rm -rf x`,
# subshell/command-substitution positions like `(rm -rf x)`/`$(rm -rf x)`,
# `cd /x && git push origin main`, and `git -C /repo push origin main` are
# caught. Splitting also fires inside quoted strings (`echo "x; rm -rf /"`
# blocks) — accepted: a string matcher can't parse shell, and over-blocking is
# the safe side here.
#
# rm check: blocks only DIRECT recursive-force `rm` (-rf / -Rf /
# --recursive --force, any flag order/case) at a command position; both flags
# must appear in the same segment that starts with `rm`.
#
# push check, three stages per push segment:
#   1. The segment must be a git push invocation. Global options (-C <path>,
#      -c k=v, --flags) may sit between `git` and `push` — but not arbitrary
#      words. NB the word boundary excludes `/`, so a path-invoked
#      `/usr/bin/git push origin main` is NOT matched — an accepted residual
#      (plain `git` is what Claude runs; nah's action classification covers
#      the path form).
#   2. Token walk after `push`: block when a token names main/master exactly —
#      bare branch, refs/heads path, or refspec destination (`x:main`, incl.
#      the `:main` deletion form).
#   3. Bare push (no explicit refspec = fewer than 2 non-flag tokens): git
#      pushes the CURRENT branch, so resolve it from the hook's cwd (honouring
#      a -C value) and block on main/master. Outside a git repo the resolution
#      fails -> allow.
# Further accepted residuals: quoted content (`echo "git push main"`) still
# blocks, and a push to main via `HEAD` with push.default=upstream tracking a
# differently-named remote branch isn't resolved.

set -f
# read -rd '' (not $(</dev/stdin)): fork-free on every bash version — the
# command substitution forks a subshell on bash <=5.3, ahead of the fast path.
IFS= read -rd '' input

# Fast path — zero forks for the overwhelming majority of commands: JSON never
# escapes ASCII letters, so a command containing "rm"/"push" always appears as
# a raw substring of the JSON. The envelope's ever-present "permission_mode"
# key itself contains "rm", which would defeat the probe on EVERY call — scrub
# the constant "ermission" first (also kills the "bypassPermissions" value).
# The scrub cannot mask a real match: a blockable `rm` token is followed by
# whitespace/quote/backslash, never the "i" that "ermission" requires, and
# "ermission" contains no "push". A residual false positive (either substring
# in cwd/paths) just falls through to the jq parse below.
# INVARIANT: every check in the segment loop below must have its trigger
# substring listed here — a check without one silently never fires.
probe=${input//ermission/}
[[ "$probe" == *rm* || "$probe" == *push* ]] || exit 0

CMD=$(jq -r '.tool_input.command // empty' <<<"$input")

block() { echo "BLOCKED: $1" >&2; exit 2; }

seps=';&|()`'
# NB when adding a check here: register its trigger substring in the fast-path
# probe at the top, or the new check never runs on most commands.
while IFS= read -r seg; do
    # --- recursive force delete ---
    if [[ "$seg" =~ ^[[:space:]]*rm([[:space:]]|$) ]]; then
        if [[ "$seg" =~ (^|[[:space:]])-[a-zA-Z]*[rR]|--recursive ]] \
            && [[ "$seg" =~ (^|[[:space:]])-[a-zA-Z]*[fF]|--force ]]; then
            block 'recursive force delete is not allowed'
        fi
        continue
    fi

    # --- direct push to main/master ---
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

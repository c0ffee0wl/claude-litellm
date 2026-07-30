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
# must appear in the same segment. The long options are matched as anchored
# `--r`/`--f` prefixes because GNU getopt_long accepts any unambiguous
# abbreviation (`--recu --forc`, minimally `--r --f`, deletes just like
# `--recursive --force`); rm has no other --r…/--f… option, and a non-option
# arg that merely starts with `--r`/`--f` over-blocks on the safe side.
# The command word and the flags are matched
# with shell quoting/escaping stripped and the command word reduced to its
# basename, so the shell-equivalent spellings `\rm`, `"rm"`, `r\m`, `/bin/rm`,
# `./rm` and `rm "-rf"` all count as rm -rf (rm's damage is irreversible, so
# unlike git below the path form is NOT an accepted residual). Leading shell
# keywords (`do`/`then`/`{`/`time`/`!`) and env-assignment prefixes are skipped
# before the command word is read, so the loop/conditional/group/assignment
# spellings (`for … do rm -rf x; done`, `{ rm -rf x; }`, `VAR=1 rm -rf x`)
# are command positions too and block.
#
# push check, three stages per push segment:
#   1. The segment must be a git push invocation. Global options (-C <path>,
#      -c k=v, --flags) may sit between `git` and `push` — but not arbitrary
#      words. Matched on the quote/backslash-stripped segment, so the
#      `"git" push` / `git "push"` spellings are caught. NB the word boundary
#      excludes `/`, so a path-invoked `/usr/bin/git push origin main` is NOT
#      matched — an accepted residual (plain `git` is what Claude runs; nah's
#      action classification covers the path form).
#   2. Token walk after `push`: block when a token names main/master exactly —
#      bare branch, the `heads/…` dwim shorthand (git resolves an unqualified
#      refspec against refs/heads/ etc., so `push origin heads/main` pushes
#      main), the full refs/heads path, or any of those as a refspec
#      destination (`x:main`, incl. the `:main` deletion form). Tokens are
#      compared with quotes/backslashes stripped and one leading `+` removed,
#      so the force-refspec forms (`+main`, `+heads/main`,
#      `+refs/heads/master`) and `ma\in` block too.
#   3. Bare push (no explicit refspec = fewer than 2 non-flag tokens) and an
#      explicit `HEAD` refspec both push the CURRENT branch, so resolve it
#      from the hook's cwd (honouring a -C value) and block on main/master.
#      Outside a git repo the resolution fails -> allow.
# Further accepted residuals: quoted content (`echo "git push main"`) still
# blocks, ANSI-C quoting (`$'rm'`) isn't decoded, a bare push from a
# branch whose push.default=upstream tracks a differently-named remote main
# isn't resolved, and `git push --all`/`--mirror` plus wildcard refspecs
# (`refs/heads/*:refs/heads/*`) — which also reach main — are not matched
# (rare in agent traffic; nah's action classification covers them).

set -f
# read -rd '' (not $(</dev/stdin)): fork-free on every bash version — the
# command substitution forks a subshell on bash <=5.3, ahead of the fast path.
IFS= read -rd '' input

# Fast path — zero forks for the overwhelming majority of commands: JSON never
# escapes ASCII letters, so a command containing "rm"/"push" always appears in
# the JSON, though possibly split by escaping (`r\m`, `"rm"` arrive as
# `r\\m`, `\"rm\"`) — hence quotes/backslashes are deleted before probing;
# that deletion only joins characters, so it can manufacture a stray false
# positive but never destroy a match that was really there. The envelope's
# ever-present "permission_mode" key itself contains "rm", which would defeat
# the probe on EVERY call — scrub the constant "ermission" first (also kills
# the "bypassPermissions" value). The scrub cannot mask a real match: a
# blockable `rm` token is followed by whitespace/quote/backslash, never the
# "i" that "ermission" requires, and "ermission" contains no "push". A
# residual false positive (either substring in cwd/paths, or manufactured by
# the joins) just falls through to the jq parse below.
# INVARIANT: every check in the segment loop below must have its trigger
# substring listed here — a check without one silently never fires.
probe=${input//ermission/}
probe=${probe//[\"\'\\]/}
[[ "$probe" == *rm* || "$probe" == *push* ]] || exit 0

CMD=$(jq -r '.tool_input.command // empty' <<<"$input")

block() { echo "BLOCKED: $1" >&2; exit 2; }

seps=';&|()`'
# NB when adding a check here: register its trigger substring in the fast-path
# probe at the top, or the new check never runs on most commands.
while IFS= read -r seg; do
    # Unquoted view of the segment: the shell strips quotes/backslashes before
    # exec, so `\rm`, `"rm"`, `r\m`, `rm "-rf"`, `"git" push` all run the real
    # thing while dodging a raw-string matcher — match against the same view
    # the kernel will see. Deleting can only join words, and over-matching is
    # the safe side here.
    useg=${seg//[\"\'\\]/}

    # --- recursive force delete ---
    # Command word = first word of the unquoted segment, reduced to its
    # basename (so /bin/rm and ./rm count) — but first skip the shell words
    # that legally sit in front of a command word without being one:
    # compound-statement keywords (`do`, `then`, `{`, ...), the `time`/`!`
    # modifiers, and env-assignment prefixes. Without this skip,
    # `for d in a b; do rm -rf "$d"; done`, `if x; then rm -rf y; fi`,
    # `{ rm -rf x; }` and `VAR=1 rm -rf x` all read their command word as the
    # keyword/assignment and the rm check never fires.
    cw=${useg#"${useg%%[![:space:]]*}"}
    while [ -n "$cw" ]; do
        w=${cw%%[[:space:]]*}
        case "$w" in
            do|then|else|elif|if|while|until|time|!|'{'|'}'|*=*) ;;
            *) break ;;
        esac
        cw=${cw#"$w"}
        cw=${cw#"${cw%%[![:space:]]*}"}
    done
    w=${cw%%[[:space:]]*}
    if [ "${w##*/}" = rm ]; then
        if [[ "$useg" =~ (^|[[:space:]])(-[a-zA-Z]*[rR]|--r) ]] \
            && [[ "$useg" =~ (^|[[:space:]])(-[a-zA-Z]*[fF]|--f) ]]; then
            block 'recursive force delete is not allowed'
        fi
        continue
    fi

    # --- direct push to main/master ---
    # Stage 1: `git`, optional global options (each `-opt`, optionally
    # followed by one value word), then `push`.
    [[ "$useg" =~ (^|[^[:alnum:]_./-])git([[:space:]]+-[^[:space:]]*([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push([[:space:]]|$) ]] || continue

    # Stage 2: segments contain no separators, so a plain word walk suffices.
    # Track a -C value seen before `push` for stage 3.
    seen_push=0 nonflag=0 head_push=0 c_dir="" prev=""
    for tok in $seg; do
        tok="${tok//[\"\'\\]/}"
        if [ "$seen_push" = 0 ]; then
            [ "$prev" = "-C" ] && c_dir="$tok"
            prev="$tok"
            [ "$tok" = "push" ] && seen_push=1
            continue
        fi
        tok="${tok#+}"  # a force refspec (+main) still targets main
        case "$tok" in
            -*|'') ;;
            main|master|heads/main|heads/master|refs/heads/main|refs/heads/master|*:main|*:master|*:heads/main|*:heads/master|*:refs/heads/main|*:refs/heads/master)
                block "Use feature branches, not direct push to ${tok##*:}" ;;
            HEAD) head_push=1 ;;
            *) nonflag=$((nonflag + 1)) ;;
        esac
    done

    # Stage 3: bare push (at most a remote named, no refspec) and an explicit
    # HEAD refspec both push the current branch — resolve it from the repo the
    # command targets.
    if [ "$seen_push" = 1 ] && { [ "$nonflag" -lt 2 ] || [ "$head_push" = 1 ]; }; then
        # cwd is only needed here — don't pay the jq fork on the common path.
        cwd=$(jq -r '.cwd // empty' <<<"$input")
        branch=$(git -C "${cwd:-$PWD}" ${c_dir:+-C "$c_dir"} symbolic-ref --quiet --short HEAD 2>/dev/null)
        case "$branch" in
            main|master) block "bare 'git push' while on $branch — use a feature branch" ;;
        esac
    fi
done <<<"${CMD//[$seps]/$'\n'}"
exit 0

#!/bin/bash
# Test battery for pretooluse-bash-guard.sh.
# Usage: test-bash-guard.sh [path-to-hook]
# Exit 0 = all expectations met.
set -u
HOOK=${1:-"$(dirname "$0")/pretooluse-bash-guard.sh"}
pass=0 fail=0
declare -a failures=()

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkrepo() { git init -q -b "$2" "$1" && git -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; }
mkrepo "$T/mainrepo" main
mkrepo "$T/featrepo" feature

# check <expected-exit 0|2> <cwd> <command> <label>
check() {
    local env rc
    env=$(jq -n --arg c "$3" --arg w "$2" '{tool_input:{command:$c},cwd:$w,permission_mode:"default"}')
    printf '%s' "$env" | bash "$HOOK" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq "$1" ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); failures+=("expect=$1 got=$rc  [$4]  $3")
    fi
}

F=$T/featrepo M=$T/mainrepo

### rm guard — must BLOCK (exit 2)
check 2 "$F" 'rm -rf /tmp/x'                'rm: plain (regression)'
check 2 "$F" 'rm -fR x'                     'rm: flag order/case (regression)'
check 2 "$F" 'rm --recursive --force x'     'rm: long flags (regression)'
check 2 "$F" 'sleep 1 & rm -rf x'           'rm: after & separator (regression)'
check 2 "$F" '(rm -rf x)'                   'rm: subshell (regression)'
check 2 "$F" 'echo hi; rm -rf x'            'rm: after ; separator (regression)'
check 2 "$F" '\rm -rf /tmp/x'               'rm: backslash-escaped (BYPASS)'
check 2 "$F" '"rm" -rf /tmp/x'              'rm: double-quoted (BYPASS)'
check 2 "$F" "'rm' -rf /tmp/x"              'rm: single-quoted (BYPASS)'
check 2 "$F" '/bin/rm -rf /tmp/x'           'rm: absolute path (BYPASS)'
check 2 "$F" './rm -rf x'                   'rm: relative path (BYPASS)'
check 2 "$F" 'r\m -rf /tmp/x'               'rm: in-word backslash (BYPASS)'
check 2 "$F" 'rm "-rf" /tmp/x'              'rm: quoted flag (BYPASS)'

### rm guard — must ALLOW (exit 0)
check 0 "$F" 'rm file.txt && cp -rf a b'    'rm: -rf belongs to cp (regression)'
check 0 "$F" 'grep -r foo /etc && rm -f c'  'rm: -r belongs to grep (regression)'
check 0 "$F" 'rm -f x'                      'rm: force only (regression)'
check 0 "$F" 'rm -r x'                      'rm: recursive only (regression)'
check 0 "$F" 'firm -rf x'                   'rm: word boundary FP guard (regression)'
check 0 "$F" 'sudo rm -rf /tmp/x'           'rm: sudo wrapper = documented residual (regression)'
check 0 "$F" 'echo rm -rf'                  'rm: not at command position (regression)'

### push guard — must BLOCK (exit 2)
check 2 "$F" 'git push origin main'             'push: plain main (regression)'
check 2 "$F" 'git push origin master'           'push: plain master (regression)'
check 2 "$F" 'git -C /repo push origin main'    'push: git -C form (regression)'
check 2 "$F" 'git push --force origin main'     'push: --force + main (regression)'
check 2 "$F" 'cd /x && git push origin main'    'push: after && (regression)'
check 2 "$F" 'git push origin feature:main'     'push: refspec dest (regression)'
check 2 "$F" 'git push origin :main'            'push: deletion refspec (regression)'
check 2 "$F" 'git push origin +feature:main'    'push: force refspec w/ src (regression)'
check 2 "$F" 'git push origin refs/heads/main'  'push: full ref (regression)'
check 2 "$M" 'git push'                         'push: bare on main (regression)'
check 2 "$M" 'git push origin'                  'push: remote-only on main (regression)'
check 2 "$M" "git -C $M push"                   'push: bare with -C to main repo (regression)'
check 2 "$F" 'git push origin +main'            'push: force refspec +main (BYPASS)'
check 2 "$F" 'git push origin +master'          'push: force refspec +master (BYPASS)'
check 2 "$F" 'git push origin +refs/heads/main' 'push: force full ref (BYPASS)'
check 2 "$M" 'git push origin HEAD'             'push: HEAD on main (BYPASS)'
check 2 "$M" 'git push origin +HEAD'            'push: +HEAD on main (BYPASS)'
check 2 "$M" 'git push -u origin HEAD'          'push: -u HEAD on main (BYPASS)'
check 2 "$F" '"git" push origin main'           'push: quoted git (BYPASS)'
check 2 "$F" 'git "push" origin main'           'push: quoted push (BYPASS)'
check 2 "$F" 'git push origin ma\in'            'push: in-word backslash (BYPASS)'

### push guard — must ALLOW (exit 0)
check 0 "$F" 'git push origin domain-fix'       'push: main substring in branch (regression)'
check 0 "$F" 'git push origin main-backup'      'push: main prefix in branch (regression)'
check 0 "$F" "git commit -m 'push to main'"     'push: quoted commit msg (regression)'
check 0 "$F" 'git push origin +feature'         'push: force feature branch'
check 0 "$F" 'git push'                         'push: bare on feature (regression)'
check 0 "$F" 'git push origin HEAD'             'push: HEAD on feature'
check 0 "$M" 'git push origin HEAD:feature'     'push: HEAD to feature dest'
check 0 "$M" "git -C $F push"                   'push: bare with -C to feature repo (regression)'
check 0 "$F" 'git stash push'                   'push: git stash push (regression)'
check 0 "$T" 'git push'                         'push: bare outside a repo (regression)'
check 0 "$F" 'echo push main'                   'push: no git (regression)'

### fast path — must ALLOW
check 0 "$F" 'ls -la'                           'fastpath: benign command'
check 0 "$F" 'echo permission test'             'fastpath: scrub regression'

echo "PASS=$pass FAIL=$fail"
if [ "$fail" -gt 0 ]; then
    printf '%s\n' "${failures[@]}"
    exit 1
fi

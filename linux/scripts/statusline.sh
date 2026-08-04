#!/bin/bash
# Two-line statusline.
# Line 1: (user@host)-[cwd] | session duration [(unsandboxed)]
# Line 2: [Model] [bar] PCT% (CTX_SIZE) | (mode-specific suffix)
#
# A red "(unsandboxed)" tag trails the duration UNLESS bash commands are
# positively confirmed contained. Claude Code does not expose sandbox state to
# statuslines (no JSON field, no env var — anthropics/claude-code#30772), so
# this is best-effort and deliberately FAIL-SAFE: the warning shows unless one
# of two things holds — (a) Claude Code itself runs inside an OUTER sandbox
# (bubblewrap via blaude, Landlock via nono, or a container; detected from the
# kernel / an env marker — see below),
# or (b) CC's per-command sandbox is effectively enabled across the full settings
# precedence chain (managed > project-local > project > user-local > user) AND
# bwrap is present (found on PATH or at /usr/bin|/bin/bwrap). "Off", "can't
# determine", and "enabled but bwrap missing" (CC's silent fallback) all warn —
# a detection gap over-warns rather than falsely reassuring.
#
# Mode is detected via ANTHROPIC_BASE_URL:
#   DIRECT  — empty or non-local: show 5h/7d rate-limit budgets (Claude.ai
#            Pro/Max), each with a reset countdown from rate_limits.*.resets_at.
#            NB a REMOTE LiteLLM router (the --harden-only setup) also lands
#            here — line 2 then shows only model + ctx, no upstream/spend info
#   LITELLM — 127.0.0.1/localhost:4000: show progress bar + model + ctx %, with the
#            upstream model (e.g. gpt-5.6-terra) appended after an arrow when
#            available via LiteLLM's /model/info endpoint, plus up to three
#            gateway spend figures — "$X/sess · $Y/day · $Z/30d":
#              /sess — THIS Claude Code session, summed from
#                      /spend/logs/session/ui. LiteLLM tags each spend log with
#                      the session id it splits out of the Anthropic
#                      metadata.user_id, which is the same id Claude Code hands
#                      the statusline. Paged, capped at 2000 requests; a
#                      truncated sum is marked "$X+/sess"
#              /day  — today in UTC (the spend view groups on DATE(startTime),
#                      and startTime is stored UTC)
#              /30d  — rolling CURRENT_DATE - 30 days, NOT calendar
#                      month-to-date
#            /day and /30d both come from one /global/spend/logs request, so
#            they cannot disagree. Each figure drops out on its own when it is
#            absent or rounds to zero.
#   OTHER   — other local proxy (CCR etc.): hide line 2 like the upstream script

# Errors must never leak to Claude Code's UI. CLAUDE_STATUSLINE_DEBUG=1 lifts
# that silence and turns on the dbg() traces below — the script is otherwise
# unintrospectable (silent by contract, opaque caches), which makes diagnosing
# a missing figure guesswork. Debug output goes to STDERR only: stdout is what
# Claude Code renders. Cost when unset is one variable test per render.
if [ -n "${CLAUDE_STATUSLINE_DEBUG:-}" ]; then
    dbg() { printf 'statusline: %s\n' "$*" >&2; }
else
    exec 2>/dev/null
    dbg() { :; }
fi

# read -d '' hits EOF (status 1) after filling $input — builtin, no cat fork.
IFS= read -rd '' input

# Inside a bubblewrap sandbox the inherited $USER/$HOSTNAME may reflect the
# outer environment, while /etc/passwd and `hostname` reflect the sandboxed
# view. The uid->name lookup reads the namespace-visible /etc/passwd with
# builtins (that IS what NSS-files does, minus the fork); `id -un` stays as
# the fallback for non-files NSS (LDAP/SSSD) or an unreadable passwd. The
# hostname comes fork-free from /proc, which is the live per-UTS-namespace
# value (statusline shares CC's namespaces), with the hostname binary as
# fallback.
user=""
while IFS=: read -r pw_name _ pw_uid _; do
    [ "$pw_uid" = "$EUID" ] && { user="$pw_name"; break; }
done < /etc/passwd
[ -n "$user" ] || user=$(id -un)
host=""
IFS= read -r host < /proc/sys/kernel/hostname
[ -n "$host" ] || host=$(hostname)
host=${host%%.*}

# Single jq fork. -e exits non-zero on null/false top-level; invalid JSON also fails.
# @tsv keeps field boundaries intact even with embedded tabs/newlines.
# Every field defaults to a NON-empty sentinel ("-"): tab is IFS-whitespace, so
# `read` collapses runs of tabs — an empty middle field (e.g. an absent
# five_hour while seven_day is present) would otherwise shift every later field
# left. "-" fails the numeric regexes downstream, so it reads as "absent".
# project_dir falls back to current_dir here (it's the /sandbox toggle location).
tsv_output=$(jq -er '[
    .workspace.current_dir // "~",
    .workspace.project_dir // .workspace.current_dir // "~",
    .cost.total_duration_ms // 0,
    .model.display_name // "unknown",
    .model.id // "-",
    (.context_window.used_percentage // 0 | floor),
    .context_window.context_window_size // 200000,
    .rate_limits.five_hour.used_percentage // "-",
    .rate_limits.seven_day.used_percentage // "-",
    .rate_limits.five_hour.resets_at // "-",
    .rate_limits.seven_day.resets_at // "-",
    .session_id // "-"
] | @tsv' <<<"$input" 2>/dev/null)

# Identity colors (root → red info_color as a warning) are resolved up here so
# the empty-input fallback below renders root-aware too.
prompt_symbol="@"
if [ "$EUID" -eq 0 ]; then
    prompt_color="94"
    info_color="31"
else
    prompt_color="32"
    info_color="34"
fi
# The session-duration counter is always blue, independent of the login
# identity, so root's red info_color doesn't bleed into it.
dur_color="34"

if [ -z "$tsv_output" ]; then
    printf "\033[1;${info_color}m(%s%s%s)\033[0m" "$user" "$prompt_symbol" "$host"
    exit 0
fi

IFS=$'\t' read -r cwd proj_dir DURATION_MS MODEL MODEL_ID PCT CTX_SIZE FIVE_H WEEK FIVE_H_RESET WEEK_RESET SESSION_ID <<<"$tsv_output"

# Sanitize numerics — defend against any surprise output from jq
[[ "$DURATION_MS" =~ ^[0-9]+$ ]] || DURATION_MS=0
[[ "$PCT" =~ ^[0-9]+$ ]] || PCT=0
[[ "$CTX_SIZE" =~ ^[0-9]+$ ]] || CTX_SIZE=200000
# "-" is the absent-field sentinel from the jq @tsv above; restore empty for
# fields whose emptiness carries meaning.
[ "$MODEL_ID" = "-" ] && MODEL_ID=""
# The session id reaches both a cache FILENAME and a query string, so pin it to
# the same conservative charset the model-keyed cache name uses. Claude Code
# sends a uuid, which survives unchanged.
[ "$SESSION_ID" = "-" ] && SESSION_ID=""
SESSION_ID="${SESSION_ID//[!A-Za-z0-9._-]/_}"

# Per-user cache dir — shared by the sandbox-verdict memo below and the
# LiteLLM endpoint caches further down. XDG_RUNTIME_DIR is already a
# 0700 per-user dir; when it is unset (ssh/cron sessions without pam_systemd,
# some sandbox launches) fall back to ~/.cache, NOT /tmp: cache names are
# predictable, and in world-writable /tmp another local user can pre-create
# them with a far-future mtime, which pins the `-nt` staleness checks below
# forever — spoofing the sandbox verdict (fail-safe "(unsandboxed)" warning
# suppressed) and feeding attacker-controlled text into the rendered line.
# The victim also can't recover: `mv` over another user's file in a sticky
# dir is EPERM, and `exec 2>/dev/null` hides it. $HOME is not world-writable,
# so pre-creation there is not possible.
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    CACHE_DIR="$XDG_RUNTIME_DIR"
else
    CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/claude-litellm"
    # `-m` with `-p` only applies to the deepest dir, so set the mode
    # explicitly (runs once, on first use — not on the render hot path).
    [ -d "$CACHE_DIR" ] || { mkdir -p "$CACHE_DIR" && chmod 700 "$CACHE_DIR"; }
fi

# Atomically persist one line per argument to file $1 ($$-suffixed tmp + mv,
# so concurrent renders can't interleave). Fork-free. One writer for every
# memo/derived file below — the target name is spelled once per call, so a
# typo can't silently strand a cache (the global `exec 2>/dev/null` would
# swallow the error).
persist() {
    local f="$1"
    shift
    printf '%s\n' "$@" > "${f}.$$.tmp" && mv "${f}.$$.tmp" "$f"
}

# Sandbox detection drives the fail-safe "(unsandboxed)" warning below.
# SANDBOXED is set only on positive confirmation that bash commands are
# contained; anything else warns.
SANDBOXED=""

# (a) Outer sandbox: Claude Code itself may run inside an external sandbox — then
# the per-command sandbox is moot and we suppress the warning. Detected, in order
# (all fork-free; the statusline shares CC's namespaces, so /proc/self is its own
# accurate view):
#   1. CLAUDE_SANDBOX / $container env marker — set by the wrapper. Deterministic
#      and mechanism-agnostic; blaude/nono can export it (recommended). NB: CC's
#      OWN built-in-sandbox runtime markers (SANDBOX_RUNTIME, the HTTP/SOCKS
#      host-proxy ports) are deliberately NOT checked — they exist only inside the
#      sandboxed bash *child*, never the statusline's host *parent* process
#      (anthropics/claude-code#30772), so reading them here is dead code.
#   2. container runtime marker files (docker/podman).
#   3. user namespace — bubblewrap (blaude) and rootless containers remap uids.
#      The initial (host) userns is ALWAYS exactly "0 0 4294967295" for every user
#      (root or 1000 — it's the namespace's map, not your uid), so any other value
#      means we're in a user namespace.
#   4. NoNewPrivs=1 — Landlock *requires* no_new_privs, so this catches nono
#      (Landlock-only, leaves no namespace) as well as bwrap. Caveat: unrelated
#      hardening (e.g. a systemd NoNewPrivileges= unit) also sets it, so this can
#      over-suppress — an accepted trade to detect Landlock, which exposes no
#      other portable marker (/proc/self/attr/landlock/domain is kernel-6.x+ only
#      and refuses self-reads). Set CLAUDE_SANDBOX to make detection exact.
outer_sandbox=""
if [ -n "${CLAUDE_SANDBOX:-}" ] || [ -n "${container:-}" ] \
   || [ -e /.dockerenv ] || [ -e /run/.containerenv ]; then
    outer_sandbox=1
elif [ -r /proc/self/uid_map ] \
     && read -r u1 u2 u3 _ < /proc/self/uid_map \
     && [[ "$u1" =~ ^[0-9]+$ && "$u2" =~ ^[0-9]+$ && "$u3" =~ ^[0-9]+$ ]] \
     && [ "$u1 $u2 $u3" != "0 0 4294967295" ]; then
    # Suppress ONLY on a well-formed, non-host mapping. An empty/garbage read
    # (read fails or fields aren't numeric) falls through rather than suppressing
    # — "can't determine" must warn, not falsely reassure (fail-safe contract).
    outer_sandbox=1
elif [ -r /proc/self/status ]; then
    while IFS=$' \t:' read -r nnp_k nnp_v _; do
        [ "$nnp_k" = NoNewPrivs ] && { [ "$nnp_v" = 1 ] && outer_sandbox=1; break; }
    done < /proc/self/status
fi

if [ -n "$outer_sandbox" ]; then
    SANDBOXED=1
else
    # (b) CC per-command sandbox: resolve the effective sandbox.enabled across
    # the settings precedence chain (highest first), taking the first file that
    # *defines* the key — an explicit higher-layer `false` wins over a lower
    # `true`. try/catch emits exactly one token, mapping an absent/malformed
    # block to "unset" (keep looking). Project-level files come from project_dir,
    # NOT current_dir which drifts on `cd`. $HOME/.claude/settings.local.json is
    # also read (a user-local override CC honours — anthropics/claude-code#47624,
    # #51704). Requires bwrap present too, else CC silently runs unsandboxed.
    # LIMITATION: this only detects sandbox enablement PERSISTED to a settings
    # file (the repo default: sandbox.enabled:true in ~/.claude/settings.json).
    # A sandbox toggled ON purely via the /sandbox picker is runtime-only — CC
    # frequently writes nothing to disk for it (#47624) and exposes no parent-
    # visible signal (#30772), so it is undetectable here and (correctly, given
    # the fail-safe contract) still warns. Enable via settings to get a reliable
    # indicator.
    SANDBOX_ON=""
    sb_root="$proj_dir"
    sb_files=()
    for sb_file in /etc/claude-code/managed-settings.json \
                   "$sb_root/.claude/settings.local.json" \
                   "$sb_root/.claude/settings.json" \
                   "$HOME/.claude/settings.local.json" \
                   "$HOME/.claude/settings.json"; do
        [ -r "$sb_file" ] && sb_files+=("$sb_file")
    done
    # Memoised verdict: the jq below used to re-parse up to 5 settings files
    # on EVERY render for a value that changes ~never. Cache line 1 = verdict
    # (1/0), lines 2..N = the readable-file list it was computed from. Reuse
    # only when that file set is unchanged AND no listed file is newer than
    # the memo (builtin -nt tests — zero forks on the steady-state render).
    # A file appearing, disappearing, or changing all invalidate; the
    # disappear case is load-bearing for the fail-safe contract (a stale
    # "sandboxed" verdict must not outlive the file that justified it).
    # Key the memo by project too (sanitized, last 64 chars): the verdict
    # depends on proj_dir via two of the candidate paths, and a shared
    # per-user file would make two concurrent sessions in different projects
    # invalidate each other every render (0% hit rate). On a truncation
    # collision the stored file-list comparison below still keeps the verdict
    # correct — it just degrades to the recompute path.
    sb_key="${proj_dir//[!A-Za-z0-9]/_}"
    # Last <=64 chars via arithmetic offset — NB `${var: -64}` is a trap: it
    # expands to EMPTY (not the whole string) when the string is shorter.
    sb_memo="${CACHE_DIR}/claude-litellm-sbon-${EUID}-${sb_key:$(( ${#sb_key} > 64 ? ${#sb_key} - 64 : 0 ))}"
    sb_fresh=""
    if [ -r "$sb_memo" ]; then
        mapfile -t sb_memo_lines < "$sb_memo"
        if [ "${sb_memo_lines[*]:1}" = "${sb_files[*]}" ]; then
            sb_fresh=1
            for sb_file in "${sb_files[@]}"; do
                [ "$sb_file" -nt "$sb_memo" ] && { sb_fresh=""; break; }
            done
        fi
    fi
    if [ -n "$sb_fresh" ]; then
        [ "${sb_memo_lines[0]}" = "1" ] && SANDBOX_ON=1
    elif [ ${#sb_files[@]} -gt 0 ]; then
        # ONE jq over all readable files (the filter runs once per input
        # document, in argument order) instead of a fork per file; the first
        # true/false token is the highest-precedence file that defines the
        # key. A malformed file aborts jq's remaining output, so files after
        # it read as "unset" — which warns, per the fail-safe contract.
        # Tokens are fixed words, so unquoted word-splitting of $sb_vals is safe.
        sb_vals=$(jq -r 'try (.sandbox.enabled) catch null | if .==true then "true" elif .==false then "false" else "unset" end' "${sb_files[@]}" 2>/dev/null)
        for sb_val in $sb_vals; do
            case "$sb_val" in
                true) SANDBOX_ON=1; break ;;
                false) SANDBOX_ON=""; break ;;
            esac
        done
        persist "$sb_memo" "${SANDBOX_ON:-0}" "${sb_files[@]}"
    fi
    # bwrap presence: prefer a PATH lookup, but fall back to the canonical apt
    # install locations. CC may invoke the statusline with a PATH lacking
    # /usr/bin, which would make `command -v bwrap` false-negative even though
    # bwrap is installed (apt ships it at /usr/bin/bwrap) — showing the warning
    # on a fully-sandboxed box. The -x checks close that gap (execute bit
    # required, so a non-exec stub can't falsely confirm).
    if [ -n "$SANDBOX_ON" ] \
       && { command -v bwrap >/dev/null 2>&1 || [ -x /usr/bin/bwrap ] || [ -x /bin/bwrap ]; }; then
        SANDBOXED=1
    fi
fi
# The verdict plus the two inputs that decide it. This block is the most
# failure-prone logic in the file (memo staleness, a truncated cache key, a
# detection gap that must fail SAFE), and "(unsandboxed)" showing on a box you
# believe is sandboxed is otherwise indistinguishable from a detection miss.
dbg "sandboxed=${SANDBOXED:-no} outer=${outer_sandbox:-no} settings_enabled=${SANDBOX_ON:-no}"

# Mode detection
MODE="DIRECT"
if [[ "$ANTHROPIC_BASE_URL" =~ ^https?://(127\.0\.0\.1|localhost):4000(/|$) ]]; then
    MODE="LITELLM"
elif [[ "$ANTHROPIC_BASE_URL" =~ ^https?://(127\.0\.0\.1|localhost)(:|/) ]]; then
    MODE="OTHER"
fi
dbg "mode=$MODE base=${ANTHROPIC_BASE_URL:-<unset>} session=${SESSION_ID:-<none>} cache_dir=$CACHE_DIR"

# Resolve the LiteLLM master key on demand, memoised — shared by /model/info
# and /global/spend. Sources, in order: env (when Claude Code passes it
# through), ~/.profile (where update_profile_export writes it),
# ~/.config/litellm/env (the systemd EnvironmentFile, mode 600). Called only
# inside the DETACHED fetch job below, so its sed forks never land on the
# render path; each job memoises for its own lifetime.
TOKEN=""; TOKEN_RESOLVED=""
resolve_token() {
    [ -n "$TOKEN_RESOLVED" ] && return
    TOKEN_RESOLVED=1
    TOKEN="${ANTHROPIC_AUTH_TOKEN:-}"
    if [ -z "$TOKEN" ] && [ -r "$HOME/.profile" ]; then
        TOKEN=$(sed -n 's/^export ANTHROPIC_AUTH_TOKEN="\(.*\)"$/\1/p' "$HOME/.profile" | head -1)
    fi
    if [ -z "$TOKEN" ] && [ -r "$HOME/.config/litellm/env" ]; then
        TOKEN=$(sed -n 's/^LITELLM_MASTER_KEY=//p' "$HOME/.config/litellm/env" | head -1)
        # EnvironmentFile values may be quoted — strip a matched surrounding pair.
        TOKEN="${TOKEN%\"}"; TOKEN="${TOKEN#\"}"
        TOKEN="${TOKEN%\'}"; TOKEN="${TOKEN#\'}"
    fi
    # Masked to the last 4 characters — a debug trace must never print the key.
    if [ -n "$TOKEN" ]; then dbg "token=resolved(…${TOKEN: -4})"; else dbg "token=NOT FOUND"; fi
}

# Freshness gate shared by both fetch helpers below: returns 1 (caller skips)
# while $1's ".ts" stamp is younger than $2 minutes, otherwise re-stamps it and
# returns 0. The stamp records the ATTEMPT — it is written BEFORE fetching — so
# an unreachable endpoint is retried at most once per window rather than piling
# up one curl per render, and the check is builtin arithmetic (no find/stat
# fork). Owned in one place so the freshness contract can't drift between the
# helpers, or get copied a third time by the next cached endpoint.
stamp_gate() {
    local cache_file="$1" max_age_min="$2" ts="" now
    IFS= read -r ts < "${cache_file}.ts"
    printf -v now '%(%s)T' -1
    [[ "$ts" =~ ^[0-9]+$ ]] && (( now - ts < max_age_min * 60 )) && return 1
    printf '%s' "$now" > "${cache_file}.ts"
}

# Refresh cache file $1 from LiteLLM endpoint $3 when the last fetch ATTEMPT
# is older than $2 minutes, then digest it with jq filter $4 into one-line
# derived file $5 (optional $6 is exposed to the filter as $id). The digest
# runs inside the already-detached background job, so the render path reads
# the derived line with a builtin `read` — zero jq forks in steady state.
# Stale-while-revalidate: the fetch runs in a DETACHED background job and the
# caller renders immediately with whatever cache already exists — a render
# never blocks on the network; a cold cache just means the data appears on a
# later render (fail-soft); stamp_gate above bounds the retry rate. The job's
# stdio redirects are load-bearing: Claude Code waits for the statusline's
# stdout to close, so the job must not inherit it. Writes atomically
# (tmp + mv); concurrent refreshes are benign ($$-suffixed tmp, atomic mv).
# --max-time 5 bounds only the background job, never a render.
fetch_litellm_cache() {
    local cache_file="$1" max_age_min="$2" endpoint="$3" digest="$4" derived="$5" key="${6:-}"
    local tmp
    stamp_gate "$cache_file" "$max_age_min" || return
    tmp="${cache_file}.$$.tmp"
    # Token resolution lives INSIDE the detached job: its sed forks never
    # block a render, and a token-less box retries once per stamp window
    # instead of re-grepping ~/.profile on every render. --arg id is passed
    # unconditionally — jq tolerates an unused or empty binding.
    (
        resolve_token
        [ -n "$TOKEN" ] || exit 0
        curl -sf --max-time 5 \
            -H "Authorization: Bearer $TOKEN" \
            "${ANTHROPIC_BASE_URL%/}/$endpoint" \
            -o "$tmp" \
            && mv "$tmp" "$cache_file" \
            && jq -r --arg id "$key" "$digest" "$cache_file" > "${derived}.$$.tmp" \
            && mv "${derived}.$$.tmp" "$derived" \
            || dbg "fetch FAILED rc=$? endpoint=$endpoint"
        # (shellcheck SC2015: the `|| dbg` firing when a LATER step fails is
        # the point — any broken link in the chain should be traced. curl -sf
        # is silent on an HTTP error, so without this a 401 from a stale key
        # produced no output at all, in debug mode or otherwise.)
        rm -f "$tmp" "${derived}.$$.tmp"
    # No `2>&1` here, deliberately: stderr is already /dev/null process-wide
    # (the exec at the top) UNLESS CLAUDE_STATUSLINE_DEBUG is set, and letting
    # the job inherit it is what puts a failing curl/jq — and resolve_token's
    # trace — in front of you under debug. Re-adding `2>&1` for symmetry would
    # silently blind the debug switch inside these jobs. Only the stdout
    # redirect is load-bearing for Claude Code.
    ) </dev/null >/dev/null &
}

# Spend for ONE Claude Code session, via /spend/logs/session/ui. Same contract
# as fetch_litellm_cache above (stamp-gated, detached, atomic, token resolved
# inside the job) — it differs only in having to PAGE: that endpoint caps
# page_size at 100 and returns no aggregate, so a long session must be summed
# across pages. It is still the right endpoint: it filters on
# `WHERE session_id = $1` (an indexed equality) and its SQL omits the heavy
# messages/response columns, whereas the public /spend/logs/v2 alias demands a
# date window and matches session_id with LIKE '%…%' — a sequential scan over
# the whole spend-logs table, once a minute, forever.
# Args: $1 raw cache, $2 max age (min), $3 sanitized session id, $4 derived file.
# The derived file carries two lines: the summed spend, then 1 if the page cap
# truncated that sum (rendered as a trailing "+" so a capped figure can't pass
# itself off as the total).
fetch_session_spend() {
    local cache_file="$1" max_age_min="$2" sid="$3" derived="$4" fresh=""
    local tmp
    [ -e "$cache_file" ] || fresh=1
    stamp_gate "$cache_file" "$max_age_min" || return
    tmp="${cache_file}.$$.tmp"
    (
        resolve_token
        [ -n "$TOKEN" ] || exit 0
        page=1 pages=1 truncated=0 ok=1
        : > "$tmp"
        while :; do
            # curl appends straight to the accumulator — jq reads concatenated
            # JSON documents natively, so the pages need no separate files and
            # no `cat` per page. A failed transfer breaks out below and $tmp is
            # discarded unread, so a partial append can never be digested.
            curl -sf --max-time 5 \
                -H "Authorization: Bearer $TOKEN" \
                "${ANTHROPIC_BASE_URL%/}/spend/logs/session/ui?session_id=${sid}&page=${page}&page_size=100" \
                >> "$tmp" || { dbg "session fetch FAILED rc=$? page=$page"; ok=""; break; }
            if [ "$page" = 1 ]; then
                # $tmp holds exactly page 1 at this point.
                pages=$(jq -r '.total_pages // 1' "$tmp")
                [[ "$pages" =~ ^[0-9]+$ ]] || pages=1
                (( pages > 20 )) && { pages=20; truncated=1; }
            fi
            (( page >= pages )) && break
            page=$(( page + 1 ))
        done
        if [ -n "$ok" ] && mv "$tmp" "$cache_file"; then
            spend=$(jq -sr '[.[].data[]?.spend // 0] | add // 0' "$cache_file") \
                && persist "$derived" "$spend" "$truncated"
            # First SUCCESSFUL fetch for this session: reap the cache files of
            # sessions that ended a week ago (this session's were just
            # written, so they are never in range). Gated on success rather
            # than on the cache being absent, so an unreachable proxy can't
            # turn this into a once-a-minute directory scan.
            [ -n "$fresh" ] && find "$CACHE_DIR" -maxdepth 1 -name "${SESSION_CACHE_PREFIX##*/}*" -mtime +7 -delete
        fi
        rm -f "$tmp"
    # No `2>&1` here, deliberately: stderr is already /dev/null process-wide
    # (the exec at the top) UNLESS CLAUDE_STATUSLINE_DEBUG is set, and letting
    # the job inherit it is what puts a failing curl/jq — and resolve_token's
    # trace — in front of you under debug. Re-adding `2>&1` for symmetry would
    # silently blind the debug switch inside these jobs. Only the stdout
    # redirect is load-bearing for Claude Code.
    ) </dev/null >/dev/null &
}

# LiteLLM lookups (cached). Falls through silently on any error — statusline
# must never block or error.
UPSTREAM_MODEL=""
SPEND_SESSION=""
SPEND_TRUNC=""
SPEND_TODAY=""
SPEND_30D=""
if [ "$MODE" = "LITELLM" ]; then
    # /model/info digest: match model_name (public alias) OR model_info.id
    # (internal uuid) — Claude Code's .model.id is usually the alias but be
    # defensive. One definition feeds both the background digest and the
    # first-render fallback below.
    MODELINFO_DIGEST='[.data[]? | select(.model_name == $id or (.model_info.id // "") == $id) | .litellm_params.model][0] // ""'

    # Resolve upstream model via /model/info (cached 5min, digested inside the
    # background fetch — the steady-state render is one builtin read). The
    # derived file is keyed by MODEL_ID in its NAME (sanitized), so concurrent
    # sessions on different models each keep their own fork-free line instead
    # of re-keying a shared one every render; the raw cache + stamp stay
    # shared (one fetch per window serves every session).
    if [ -n "$MODEL_ID" ]; then
        CACHE_FILE="${CACHE_DIR}/claude-litellm-modelinfo-${EUID}.json"
        MODELINFO_DERIVED="${CACHE_DIR}/claude-litellm-modelinfo-${EUID}-${MODEL_ID//[!A-Za-z0-9._-]/_}.derived"
        fetch_litellm_cache "$CACHE_FILE" 5 "model/info" "$MODELINFO_DIGEST" "$MODELINFO_DERIVED" "$MODEL_ID"
        IFS= read -r UPSTREAM_MODEL < "$MODELINFO_DERIVED"
        if [ ! -e "$MODELINFO_DERIVED" ] && [ -s "$CACHE_FILE" ]; then
            # No derived line for THIS model yet (first render after a model
            # switch / in a new session, or a cache from a pre-digest
            # version): derive once and persist — even an empty result, so
            # the branch is terminal and can't re-fork every render.
            UPSTREAM_MODEL=$(jq -r --arg id "$MODEL_ID" "$MODELINFO_DIGEST" "$CACHE_FILE" 2>/dev/null)
            persist "$MODELINFO_DERIVED" "$UPSTREAM_MODEL"
        fi
        UPSTREAM_MODEL="${UPSTREAM_MODEL#*/}"
        # This value is rendered through `echo -e`, which interprets \e/\033:
        # keep it to a conservative model-id charset so neither a hostile
        # gateway response nor a tampered cache file can inject terminal
        # escape sequences into the user's statusline. (SPEND is already
        # regex-gated below; this is the only free-text field.)
        UPSTREAM_MODEL="${UPSTREAM_MODEL//[!A-Za-z0-9._:\/-]/}"
        dbg "upstream_model=[$UPSTREAM_MODEL] (model_id=[$MODEL_ID])"
    fi

    # Today's + trailing-30-day gateway spend via /global/spend/logs (cached
    # 1min, digested inside the background fetch). The master key is proxy
    # admin, so user_api_key_auth passes and the endpoint takes its admin
    # branch: one {date, spend} row per day of the MonthlyGlobalSpend view.
    # Both figures come from that single request and so can never disagree.
    # NB the view is "startTime >= CURRENT_DATE - INTERVAL '30 days'" — a
    # rolling 30-day window, not calendar month-to-date, hence the "/30d"
    # label. startTime is stored UTC and the view groups on DATE(startTime), so
    # "today" must be resolved in UTC too — jq's strftime is gmtime-based
    # whatever TZ says, so the date is computed IN the filter. It used to come
    # from a `TZ=UTC printf -v` on the render path, which leans on an
    # assignment prefix reaching a builtin's strftime; that resolved empty on
    # at least one box, and an empty date silently matches no row, so the /day
    # figure vanished while /30d (which needs no date) kept working. Deriving
    # it here also puts it where it belongs: evaluated in the background job at
    # digest time, not on the render path. An unexpected body (a
    # prometheus-backed proxy answers this endpoint in a different shape)
    # digests to two empty lines rather than a jq error, so the figures drop
    # out instead of the cache silently going stale.
    # `gmtime|strftime`, not the shorter `now|strftime`: jq only grew the
    # accept-a-bare-number form later, and feeding a number to strftime on an
    # older jq is a filter ERROR — which would blank BOTH figures instead of
    # the one this fix is about. gmtime -> broken-down time is accepted by
    # every version.
    SPEND_DIGEST='if type=="array" then
        (now|gmtime|strftime("%Y-%m-%d")) as $today
        | ([.[] | select((.spend|type)=="number")]) as $r
        | ([$r[] | select((.date|tostring)[0:10]==$today) | .spend] | add // 0),
          ([$r[].spend] | add // 0)
        else "","" end'
    # Basename deliberately differs from the single-figure version's: that
    # file holds one line, which would read here as a today-only value.
    SPEND_CACHE="${CACHE_DIR}/claude-litellm-spendlogs-${EUID}.json"
    SPEND_DERIVED="${CACHE_DIR}/claude-litellm-spendlogs-${EUID}.derived"
    fetch_litellm_cache "$SPEND_CACHE" 1 "global/spend/logs" "$SPEND_DIGEST" "$SPEND_DERIVED"
    { IFS= read -r SPEND_TODAY; IFS= read -r SPEND_30D; } < "$SPEND_DERIVED"
    if [ ! -e "$SPEND_DERIVED" ] && [ -s "$SPEND_CACHE" ]; then
        # Raw cache exists but no derived lines yet: derive once and persist —
        # even an empty result, so the branch is terminal and can't re-fork
        # every render.
        mapfile -t spend_lines < <(jq -r "$SPEND_DIGEST" "$SPEND_CACHE" 2>/dev/null)
        SPEND_TODAY="${spend_lines[0]}"
        SPEND_30D="${spend_lines[1]}"
        persist "$SPEND_DERIVED" "$SPEND_TODAY" "$SPEND_30D"
    fi

    # Spend for THIS session (cached 1min). LiteLLM tags every spend log with
    # Claude Code's own session id: it splits the Anthropic metadata.user_id
    # ("user_<hash>_account__session_<uuid>") on "_session_" into
    # litellm_session_id, which becomes the logging payload's trace_id and
    # lands in the indexed SpendLogs.session_id column. So this is the true
    # gateway cost of the session on screen — the one figure Claude Code
    # cannot produce itself behind a gateway, since its own cost accounting
    # prices against an Anthropic table that has no entry for the served
    # model. Cache/derived are keyed by session id so concurrent sessions
    # don't overwrite each other's figure.
    if [ -n "$SESSION_ID" ]; then
        # Spelled once: fetch_session_spend derives its reap glob from this
        # prefix, so a change to the naming scheme can't silently strand the
        # cleanup (the script's `exec 2>/dev/null` would hide the miss).
        SESSION_CACHE_PREFIX="${CACHE_DIR}/claude-litellm-sess-${EUID}-"
        SESSION_CACHE="${SESSION_CACHE_PREFIX}${SESSION_ID}.json"
        SESSION_DERIVED="${SESSION_CACHE_PREFIX}${SESSION_ID}.derived"
        fetch_session_spend "$SESSION_CACHE" 1 "$SESSION_ID" "$SESSION_DERIVED"
        { IFS= read -r SPEND_SESSION; IFS= read -r SPEND_TRUNC; } < "$SESSION_DERIVED"
    fi
    # Raw derived values, before fmt_spend decides which ones survive. An empty
    # figure here means "no derived line yet" (cold cache, failed fetch, or a
    # digest that matched nothing); a "0" means the gateway really reported
    # zero. The two look identical on the rendered line, which is exactly the
    # ambiguity this trace exists to resolve.
    dbg "spendlogs=$SPEND_CACHE"
    dbg "  today=[$SPEND_TODAY] 30d=[$SPEND_30D]"
    dbg "session=${SESSION_CACHE:-<no session id>}"
    dbg "  session=[$SPEND_SESSION] truncated=[$SPEND_TRUNC]"
fi

# Line 1: identity + directory + (duration, only once the first turn completes)
printf "\033[1;${prompt_color}m(\033[1;${info_color}m%s%s%s\033[0;1;${prompt_color}m)\033[0;${prompt_color}m-[\033[0;1m%s\033[0;${prompt_color}m]" \
    "$user" "$prompt_symbol" "$host" "$cwd"
if [ "$DURATION_MS" -gt 0 ]; then
    printf " | \033[0;${dur_color}m%sm %ss" \
        "$((DURATION_MS / 60000))" "$(((DURATION_MS % 60000) / 1000))"
fi
[ -z "$SANDBOXED" ] && printf " \033[31m(unsandboxed)\033[0m"
printf "\033[0m\n"

# Line 2 is suppressed for unknown local proxies (data shape is unclear)
[ "$MODE" = "OTHER" ] && exit 0

GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'

# Compact "time remaining" from an epoch-seconds timestamp, returned via the
# RESET_IN global (printf -v, no command-substitution fork). Empty on invalid
# input, "now" once the window has elapsed.
fmt_reset() {
    local at="$1" now diff d h m
    RESET_IN=""
    [[ "$at" =~ ^[0-9]+$ ]] || return 0
    printf -v now '%(%s)T' -1; diff=$((at - now)); (( diff <= 0 )) && { RESET_IN="now"; return 0; }
    d=$((diff/86400)); h=$(((diff%86400)/3600)); m=$(((diff%3600)/60))
    if   (( d > 0 )); then printf -v RESET_IN '%dd%dh' "$d" "$h"
    elif (( h > 0 )); then printf -v RESET_IN '%dh%dm' "$h" "$m"
    else printf -v RESET_IN '%dm' "$m"; fi
}

# Format one USD figure, returned via the SPEND_FMT global (builtin printf -v,
# no fork — same shape as fmt_reset). 2 decimals when that shows a visible
# cent, else 4; empty when the input is not a well-formed number or rounds away
# to nothing, which is how a figure drops out of the line entirely. That
# numeric gate is also what keeps these values safe for the `echo -e` below.
fmt_spend() {
    SPEND_FMT=""
    [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 0
    LC_ALL=C printf -v SPEND_FMT '%.2f' "$1"
    if [ "$SPEND_FMT" = "0.00" ]; then
        LC_ALL=C printf -v SPEND_FMT '%.4f' "$1"
        [ "$SPEND_FMT" = "0.0000" ] && SPEND_FMT=""
    fi
}

# Color-coded progress bar
if [ "$PCT" -ge 90 ]; then BAR_COLOR="$RED"
elif [ "$PCT" -ge 70 ]; then BAR_COLOR="$YELLOW"
else BAR_COLOR="$GREEN"; fi

FILLED=$((PCT / 10)); EMPTY=$((10 - FILLED))
BAR=""
[ "$FILLED" -gt 0 ] && printf -v FILL "%${FILLED}s" && BAR="${FILL// /█}"
[ "$EMPTY" -gt 0 ] && printf -v PAD "%${EMPTY}s" && BAR="${BAR}${PAD// /░}"

# Context window size label (handles 400K, 1M, 1.5M etc.)
if (( CTX_SIZE >= 1000000 )); then
    if (( CTX_SIZE % 1000000 == 0 )); then
        CTX_LABEL="$((CTX_SIZE / 1000000))M"
    else
        tenths=$((CTX_SIZE / 100000))
        CTX_LABEL="${tenths:0:-1}.${tenths: -1}M"
    fi
else
    CTX_LABEL="$((CTX_SIZE / 1000))K"
fi

MODEL_LABEL="$MODEL"
# Skip the arrow when upstream is just the model_id with its provider prefix
# stripped (e.g. MODEL_ID=azure/gpt-5.6-terra, UPSTREAM_MODEL=gpt-5.6-terra) — that's the
# alias-free config where Public Name == LiteLLM model, so the arrow is noise.
[ -n "$UPSTREAM_MODEL" ] && [ "$UPSTREAM_MODEL" != "$MODEL_ID" ] && [ "$UPSTREAM_MODEL" != "${MODEL_ID#*/}" ] && MODEL_LABEL="${MODEL} → ${UPSTREAM_MODEL}"
LINE2="${GREEN}[${MODEL_LABEL}] ${BAR_COLOR}${BAR}${GREEN} ${PCT}% (${CTX_LABEL})"

# Mode-specific suffix. LC_ALL=C pins awk/printf to '.' decimals regardless of
# the inherited locale; the regex requires a well-formed number (no multi-dot).
SUFFIX=""
if [ "$MODE" = "DIRECT" ]; then
    # Anthropic Pro/Max: 5h and 7d budget percentages, each with a reset
    # countdown. All builtin printf -v — no subshell forks.
    if [[ "$FIVE_H" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        fmt_reset "$FIVE_H_RESET"
        LC_ALL=C printf -v pct '%.0f' "$FIVE_H"
        SUFFIX="5h: ${pct}%${RESET_IN:+ ($RESET_IN)}"
    fi
    if [[ "$WEEK" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        fmt_reset "$WEEK_RESET"
        LC_ALL=C printf -v pct '%.0f' "$WEEK"
        SUFFIX="${SUFFIX:+$SUFFIX, }7d: ${pct}%${RESET_IN:+ ($RESET_IN)}"
    fi
elif [ "$MODE" = "LITELLM" ]; then
    # Three gateway spend figures, each dropping out on its own when absent or
    # zero (a fresh session shows only day + 30d; an unreachable proxy shows no
    # suffix at all). The labels carry the meaning: "/sess" is this Claude Code
    # session, "/day" is today in UTC, "/30d" is a rolling window and NOT
    # calendar month-to-date. Assembled with the same ${SUFFIX:+…} idiom as the
    # DIRECT branch above.
    trunc=""
    [ "$SPEND_TRUNC" = "1" ] && trunc="+"   # sum hit the page cap; a floor, not a total
    fmt_spend "$SPEND_SESSION"
    [ -n "$SPEND_FMT" ] && SUFFIX="\$${SPEND_FMT}${trunc}/sess"
    fmt_spend "$SPEND_TODAY"
    [ -n "$SPEND_FMT" ] && SUFFIX="${SUFFIX:+$SUFFIX · }\$${SPEND_FMT}/day"
    fmt_spend "$SPEND_30D"
    [ -n "$SPEND_FMT" ] && SUFFIX="${SUFFIX:+$SUFFIX · }\$${SPEND_FMT}/30d"
fi

dbg "suffix=[$SUFFIX]"
[ -n "$SUFFIX" ] && LINE2="${LINE2} | ${SUFFIX}"

echo -e "${LINE2}${RESET}"

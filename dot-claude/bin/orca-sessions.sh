#!/usr/bin/env bash
# Report every live Claude session Orca manages, one JSON object per line.
#
# Needs no network: Orca is local IPC. `worktree ps` reports each agent's state
# directly, and the scrollback carries the prose Orca does not model.
#
#   bucket  WORKING  mid-turn
#           DECIDE   blocked on a question or a permission prompt
#           ERRORED  an API or 1Password error ended the last turn
#           ?        stopped; the caller reads `recap` to tell GO from DONE
#
# Fields: handle title cwd idle_min state tool turn error call recap bucket
set -euo pipefail

LIMIT=80
MAX_IDLE=360
TABLE=0
SELF="${ORCA_TERMINAL_HANDLE:-}"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  cat <<'EOF'

Usage: orca-sessions.sh [--limit N] [--self HANDLE] [--max-idle MIN] [--table]

  --limit N       tail lines to read per session (default: 80)
  --self HANDLE   this session's handle, whose tab is skipped
                  (default: $ORCA_TERMINAL_HANDLE)
  --max-idle MIN  skip stopped sessions idle longer than this (default: 360);
                  a working or waiting session is always reported
  --table         human-readable board instead of JSONL
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --limit)    LIMIT="$2"; shift 2 ;;
    --self)     SELF="$2"; shift 2 ;;
    --max-idle) MAX_IDLE="$2"; shift 2 ;;
    --table)    TABLE=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for c in orca jq; do
  command -v "$c" >/dev/null || { echo "$c not found on PATH" >&2; exit 1; }
done

# Error text confirmed present in this machine's own transcripts.
ERR='API Error|fetch failed|Connection error|reach the API server|session expired|agent refused operation|Permission denied \(publickey\)|error: 1Password:'

# A ⏺ or $ line is the last tool call, minus the tips that share the ⎿ marker.
# Errors match in the last 12 lines only: a session that has been *discussing*
# "API Error" is not one that suffered it, and a real error is always at the bottom.
# The spinner's own clock stands in when `worktree ps` has no row for the pane,
# which is how a session outside a git worktree still buckets as WORKING.
read -r -d '' SCRAPE <<'JQ' || true
[ .result.terminal.tail[] | gsub("^\\s+|\\s+$"; "") | select(length > 0) ] as $l
| ([ $l[] | capture("\\w+…\\s*\\((?:(?<m>\\d+)m\\s*)?(?<s>\\d+)s") ] | first) as $spin
| {
    handle: $handle,
    title: $title,
    cwd: $cwd,
    idle_min: $idle,
    state: $state,
    tool: $tool,
    turn: (if $turn != "" then $turn
           elif $spin then (($spin.m // "0") + "m" + $spin.s + "s")
           else "" end),
    error: ([ $l[-12:][] | match($err).string ] | unique | join(";")),
    call: ([ $l[]
             | capture("^(?:⏺\\s*|(?:⎿\\s*)?\\$\\s*)(?<c>.+)").c
             | select(startswith("Tip:") | not) ] | last // ""),
    recap: ([ $l[] | select(test("recap:")) ] | last // "")
  }
| .bucket = (if   $state == "working" or ($state == "" and $spin) then "WORKING"
             elif $state == "waiting" then "DECIDE"
             elif .error != ""        then "ERRORED"
             else "?" end)
| .call  |= (gsub("\\s+"; " ") | .[0:70])
| .recap |= (gsub("\\s+"; " ") | .[0:220])
JQ

own_tab=""
if [ -n "$SELF" ]; then
  own_tab=$(orca terminal show --terminal "$SELF" --json 2>/dev/null \
            | jq -r '.result.terminal.tabId // empty') || true
fi

now=$(( $(date +%s) * 1000 ))

# `worktree ps` keys its agents by paneKey, which is exactly "<tabId>:<leafId>"
# from `terminal list`. That join is what carries state onto a handle.
panes=$(orca worktree ps --json 2>/dev/null | jq -c '
  [ .result.worktrees[] | .agents[]?
    | select(.agentType == "claude")
    | { key: .paneKey,
        value: { state: .state, tool: (.toolName // ""), since: .stateStartedAt } } ]
  | from_entries') || panes='{}'

# One tab hands out several handle aliases, so keep one row per tab. A null
# lastOutputAt is no evidence the session was ever alive. `done` carries no
# clock, since the state it started is the absence of work.
orca terminal list --json | jq -r --arg own "$own_tab" --argjson panes "$panes" --argjson now "$now" '
  .result.terminals
  | map(select(.connected and (.orphaned | not)
               and .agentIdentity == "claude" and .lastOutputAt))
  | unique_by(.tabId)
  | map(select(.tabId != $own))
  | .[]
  | ($panes[.tabId + ":" + .leafId] // {}) as $p
  | [ .handle, (.title // ""), (.worktreePath // ""), .lastOutputAt,
      ($p.state // ""), ($p.tool // ""),
      (if ($p.since // null) == null or $p.state == "done" then ""
       else (($now - $p.since) / 1000 | floor)
            | (. / 60 | floor | tostring) + "m" + (. % 60 | tostring) + "s" end) ]
  | @tsv
' | while IFS=$'\t' read -r handle title cwd lastout state tool turn; do
      idle=$(( (now - lastout) / 60000 ))
      # Age only retires a stopped session. One still working or still holding a
      # question is live however long it has sat, and the stalest question is the
      # one most worth surfacing.
      if [ "$state" = "done" ] || [ -z "$state" ]; then
        if [ "$idle" -lt 0 ] || [ "$idle" -gt "$MAX_IDLE" ]; then continue; fi
      fi
      orca terminal read --terminal "$handle" --limit "$LIMIT" --json 2>/dev/null \
        | jq -c --arg handle "$handle" --arg title "${title:0:40}" --arg cwd "$cwd" \
               --argjson idle "$idle" --arg err "$ERR" \
               --arg state "$state" --arg tool "$tool" --arg turn "$turn" "$SCRAPE" \
        || echo "skipped $handle" >&2
    done \
  | jq -s -r --argjson table "$TABLE" '
      sort_by(.bucket != "DECIDE", .bucket == "WORKING", .idle_min)
      | if $table | not then .[] | tojson
        else
          "BUCKET  |    turn |  idle | title                                    | detail",
          (.[] | "\(.bucket | . + " " * (7 - length))"
                 + " | \(.turn // "-" | if . == "" then "-" else . end
                          | " " * (7 - length) + .)"
                 + " | \(.idle_min | tostring | " " * (4 - length) + .)m"
                 + " | \(.title + " " * (40 - (.title | length)))"
                 + " | \((.error // "") as $e
                         | (if $e != "" then $e else (if .call != "" then .call else .recap end) end)
                         | .[0:70])")
        end'

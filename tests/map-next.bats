bats_require_minimum_version 1.5.0
load helpers/assert

# map-next reads a real bd tracker, so every fixture below is built with bd
# itself rather than canned JSON: the frontier, the claim guard and the
# metadata it reads are bd's own semantics. Orca and gh are stubbed. Each stub
# reads its knobs from env and files under $TMP at call time.
MAP_NEXT="${BATS_TEST_DIRNAME}/../dot-claude/skills/map-next/map-next"

# One tracker for the whole file: bd init takes seconds, a create well under
# one. Every test charts its own map, so tests never see each other's tickets.
setup_file() {
  command -v bd >/dev/null || skip "no bd"
  command -v jq >/dev/null || skip "no jq"
  TRACKER="$(mktemp -d)"
  export TRACKER
  (
    cd "$TRACKER" || exit 1
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git init -q
    bd init --prefix mn --quiet >/dev/null 2>&1
  )
  export BEADS_DIR="$TRACKER/.beads"
}

teardown_file() { rm -rf "$TRACKER"; }

setup() {
  TMP="$(mktemp -d)"
  export BEADS_DIR="$TRACKER/.beads"
  export BEADS_ACTOR=tester
  export STUB_BIN="$TMP/bin"
  mkdir -p "$STUB_BIN"
  export ORCA_LOG="$TMP/orca.log" ORCA_WORKTREES="$TMP/worktrees" GH_PR_STATES="$TMP/pr-states"
  : >"$ORCA_LOG"
  : >"$ORCA_WORKTREES"
  : >"$GH_PR_STATES"
  export ORCA_CURRENT_ID="repo::/wt/chart"
  unset ORCA_PARENT_KEY ORCA_CREATE_EXIT ORCA_LIST_JSON

  # Worktree list: ORCA_LIST_JSON verbatim when set, else one row per name in
  # $ORCA_WORKTREES. Current: this worktree
  # and, when ORCA_PARENT_KEY is set, its parent. Create: logs its argv as a
  # JSON array and registers the name, so the next list sees it live.
  cat >"$STUB_BIN/orca" <<'EOF'
#!/bin/bash
case "$1 $2" in
"worktree list")
  [ -n "${ORCA_LIST_JSON:-}" ] && { printf '%s\n' "$ORCA_LIST_JSON"; exit 0; }
  jq -Rn '{ok: true, result: {worktrees: [inputs | select(. != "") | {id: ("repo::/wt/" + .), displayName: ., isArchived: false}]}}' <"$ORCA_WORKTREES"
  ;;
"worktree current")
  jq -n --arg id "$ORCA_CURRENT_ID" --arg pk "${ORCA_PARENT_KEY:-}" \
    '{ok: true, result: {worktree: {id: $id, workspaceLineage: (if $pk == "" then null else {parentWorkspaceKey: $pk} end)}}}'
  ;;
"worktree create")
  shift 2
  jq -cn '$ARGS.positional' --args -- "$@" >>"$ORCA_LOG"
  if [ "${ORCA_CREATE_EXIT:-0}" -ne 0 ]; then
    echo "orca: create failed" >&2
    exit "$ORCA_CREATE_EXIT"
  fi
  name=""
  while [ $# -gt 0 ]; do
    [ "$1" = --name ] && name="$2"
    shift
  done
  echo "$name" >>"$ORCA_WORKTREES"
  jq -n --arg n "$name" '{ok: true, result: {worktree: {id: ("repo::/wt/" + $n), displayName: $n}}}'
  ;;
*)
  echo "orca stub: unexpected $*" >&2
  exit 64
  ;;
esac
EOF
  # gh pr view <url> --json state: the state $GH_PR_STATES pairs with the url.
  cat >"$STUB_BIN/gh" <<'EOF'
#!/bin/bash
[ "$1 $2" = "pr view" ] || { echo "gh stub: unexpected $*" >&2; exit 64; }
state="$(awk -v u="$3" '$1 == u { print $2 }' "$GH_PR_STATES")"
[ -n "$state" ] || { echo "no pull requests found" >&2; exit 1; }
jq -n --arg s "$state" '{state: $s}'
EOF
  chmod +x "$STUB_BIN/orca" "$STUB_BIN/gh"
  OLD_PATH="$PATH"
  export PATH="$STUB_BIN:$PATH"
  # Run from a directory that is neither the tracker nor this repo: map-next
  # must work from whatever repo a session sits in.
  cd "$TMP" || exit 1
}

teardown() {
  export PATH="$OLD_PATH"
  rm -rf "$TMP"
}

# --- fixtures ----------------------------------------------------------------

# new_map [not-yet-specified] [decisions-so-far] [out-of-scope]: prints the id.
new_map() {
  local body
  body="$(printf '## Destination\n\nA thing.\n\n## Notes\n\nNone.\n\n## Decisions so far\n\n<!-- one line per closed ticket -->\n%s\n\n## Not yet specified\n\n<!-- fog -->\n%s\n\n## Out of scope\n\n%s\n' "${2:-}" "${1:-}" "${3:-}")"
  bd create --type=epic --labels wayfinder:map --title "Map $BATS_TEST_NUMBER" --description "$body" --silent
}

# ticket <map> <type> [title]: prints the id.
ticket() {
  bd create --parent="$1" --type=decision --no-inherit-labels --labels "wayfinder:$2" \
    --title "${3:-$2 ticket}" --silent
}

block() { bd dep add "$1" "$2" >/dev/null; }
claim() { bd update "$1" --status in_progress --assignee tester >/dev/null; }
close_ticket() { bd close "$1" --reason resolved >/dev/null; }
live() { echo "$1" >>"$ORCA_WORKTREES"; }
set_map_body_decision() {
  local map="$1" line="$2" body
  body="$(bd show "$map" --json | jq -r '.[0].description')"
  body="${body/<!-- one line per closed ticket -->/<!-- one line per closed ticket -->
$line}"
  bd update "$map" --description "$body" >/dev/null
}

# actions <json>: one compact line per action.
actions() { jq -c '.actions[]' <<<"$1"; }
# kinds <json>: the action kinds in order, space-separated.
kinds() { jq -r '[.actions[].action] | join(" ")' <<<"$1"; }
creates() { grep -c . "$ORCA_LOG" || true; }

run_map_next() {
  run --separate-stderr "$MAP_NEXT" "$@"
}

# --- usage ---------------------------------------------------------------------

@test "no map id prints usage and exits 2" {
  run_map_next
  equals "$status" 2
  contains "$stderr" "usage: map-next <map-id>"
}

@test "an unknown flag prints usage and exits 2" {
  run_map_next mn-x --frobnicate
  equals "$status" 2
  contains "$stderr" "usage: map-next <map-id>"
}

@test "a map id bd cannot find exits 1 and names it" {
  run_map_next mn-nope
  equals "$status" 1
  contains "$stderr" "mn-nope"
}

# --- launch: the frontier -------------------------------------------------------

@test "frontier tickets with no session each get a launch with the wayfinder prompt" {
  map="$(new_map)"
  r="$(ticket "$map" research "Look it up")"
  g="$(ticket "$map" grilling "Decide it")"
  run_map_next "$map"
  equals "$status" 0
  equals "$(jq -r .map <<<"$output")" "$map"
  equals "$(kinds "$output")" "launch launch"
  equals "$(jq -r --arg t "$r" '.actions[] | select(.ticket == $t) | .prompt' <<<"$output")" "/wayfinder $map $r"
  equals "$(jq -r --arg t "$g" '.actions[] | select(.ticket == $t) | .type' <<<"$output")" "grilling"
  equals "$(jq -r --arg t "$g" '.actions[] | select(.ticket == $t) | .title' <<<"$output")" "Decide it"
}

@test "without --launch nothing is claimed and no session starts" {
  map="$(new_map)"
  t="$(ticket "$map" research)"
  run_map_next "$map"
  equals "$status" 0
  equals "$(creates)" 0
  equals "$(bd show "$t" --json | jq -r '.[0].status')" open
}

@test "a blocked ticket is not launched" {
  map="$(new_map)"
  a="$(ticket "$map" research)"
  b="$(ticket "$map" grilling)"
  block "$b" "$a"
  run_map_next "$map"
  equals "$(jq -r '[.actions[].ticket] | join(" ")' <<<"$output")" "$a"
}

# --- wait and stale ---------------------------------------------------------------

@test "a claimed ticket with a live session is a wait" {
  map="$(new_map)"
  t="$(ticket "$map" grilling)"
  claim "$t"
  live "$t"
  run_map_next "$map"
  equals "$status" 0
  equals "$(actions "$output")" "$(jq -cn --arg t "$t" '{action: "wait", ticket: $t, title: "grilling ticket", type: "grilling"}')"
}

@test "a claimed ticket with no live session is a stale claim" {
  map="$(new_map)"
  t="$(ticket "$map" grilling)"
  claim "$t"
  run_map_next "$map"
  equals "$status" 0
  equals "$(kinds "$output")" "stale"
  equals "$(jq -r '.actions[0].ticket' <<<"$output")" "$t"
}

@test "an archived worktree is not a live session" {
  map="$(new_map)"
  t="$(ticket "$map" grilling)"
  claim "$t"
  ORCA_LIST_JSON="$(jq -cn --arg t "$t" '{ok: true, result: {worktrees: [{id: ("repo::/wt/" + $t), displayName: $t, isArchived: true}]}}')"
  export ORCA_LIST_JSON
  run_map_next "$map"
  equals "$(kinds "$output")" "stale"
}

# --- missing decision -----------------------------------------------------------------

@test "a closed ticket missing from Decisions so far is flagged" {
  map="$(new_map)"
  t="$(ticket "$map" grilling "Settled thing")"
  close_ticket "$t"
  run_map_next "$map"
  equals "$status" 0
  equals "$(actions "$output")" "$(jq -cn --arg t "$t" '{action: "flag", ticket: $t, title: "Settled thing", reason: "closed but missing from Decisions so far"}')"
}

@test "a closed ticket indexed in Decisions so far or Out of scope is not flagged" {
  map="$(new_map)"
  a="$(ticket "$map" grilling "Settled")"
  b="$(ticket "$map" grilling "Ruled out")"
  close_ticket "$a"
  close_ticket "$b"
  set_map_body_decision "$map" "- [Settled](bd:$a): yes"
  body="$(bd show "$map" --json | jq -r '.[0].description')"
  bd update "$map" --description "$body
- [Ruled out](bd:$b): past the destination" >/dev/null
  run_map_next "$map"
  lacks "$(kinds "$output")" "flag"
}

@test "a ticket id named only outside the two index sections still counts as missing" {
  map="$(new_map "- revisit what $RANDOM means")"
  t="$(ticket "$map" grilling)"
  close_ticket "$t"
  body="$(bd show "$map" --json | jq -r '.[0].description')"
  bd update "$map" --description "${body/A thing./A thing, see $t.}" >/dev/null
  run_map_next "$map"
  contains "$(kinds "$output")" "flag"
}

# --- handoff ------------------------------------------------------------------------

@test "the way is clear: every ticket closed and indexed, no fog, is a handoff" {
  map="$(new_map)"
  t="$(ticket "$map" grilling)"
  close_ticket "$t"
  set_map_body_decision "$map" "- [x](bd:$t): y"
  run_map_next "$map"
  equals "$status" 0
  equals "$(kinds "$output")" "handoff"
  contains "$(jq -r '.actions[0].prompt' <<<"$output")" "/to-spec-to-tickets"
  contains "$(jq -r '.actions[0].prompt' <<<"$output")" "$map"
}

@test "fog left in Not yet specified with no open tickets is fog, not a handoff" {
  map="$(new_map "- how the sync settles")"
  run_map_next "$map"
  equals "$status" 0
  equals "$(kinds "$output")" "fog"
}

@test "an open ticket withholds the handoff" {
  map="$(new_map)"
  t="$(ticket "$map" grilling)"
  b="$(ticket "$map" grilling)"
  block "$b" "$t"
  claim "$t"
  live "$t"
  run_map_next "$map"
  equals "$(kinds "$output")" "wait"
}

@test "a flag withholds the handoff, since the handoff reads the map's record" {
  map="$(new_map)"
  t="$(ticket "$map" grilling)"
  close_ticket "$t"
  run_map_next "$map"
  equals "$(kinds "$output")" "flag"
}

@test "an unmerged docs PR on the map withholds the handoff" {
  map="$(new_map)"
  a="$(ticket "$map" grilling)"
  b="$(ticket "$map" grilling)"
  bd update "$a" --set-metadata docs_pr=https://github.com/o/r/pull/1 >/dev/null
  bd update "$b" --set-metadata docs_pr=https://github.com/o/r/pull/2 >/dev/null
  close_ticket "$a"
  close_ticket "$b"
  set_map_body_decision "$map" "- [a](bd:$a) and [b](bd:$b)"
  printf '%s %s\n' https://github.com/o/r/pull/1 MERGED https://github.com/o/r/pull/2 OPEN >"$GH_PR_STATES"
  run_map_next "$map"
  equals "$status" 0
  equals "$(actions "$output")" "$(jq -cn --arg t "$b" '{action: "wait", ticket: $t, docs_pr: "https://github.com/o/r/pull/2", state: "OPEN"}')"
}

@test "every docs PR merged lets the handoff through" {
  map="$(new_map)"
  a="$(ticket "$map" grilling)"
  bd update "$a" --set-metadata docs_pr=https://github.com/o/r/pull/1 >/dev/null
  close_ticket "$a"
  set_map_body_decision "$map" "- [a](bd:$a)"
  printf '%s %s\n' https://github.com/o/r/pull/1 MERGED >"$GH_PR_STATES"
  run_map_next "$map"
  equals "$(kinds "$output")" "handoff"
}

@test "a docs PR the forge cannot read fails the run rather than handing off" {
  map="$(new_map)"
  a="$(ticket "$map" grilling)"
  bd update "$a" --set-metadata docs_pr=https://github.com/o/r/pull/9 >/dev/null
  close_ticket "$a"
  set_map_body_decision "$map" "- [a](bd:$a)"
  run_map_next "$map"
  equals "$status" 1
  contains "$stderr" "https://github.com/o/r/pull/9"
}

@test "a claimed map with a live handoff session is a wait on the handoff" {
  map="$(new_map)"
  claim "$map"
  live "$map-handoff"
  run_map_next "$map"
  equals "$(actions "$output")" "$(jq -cn --arg m "$map" '{action: "wait", ticket: $m, handoff: true}')"
}

@test "a claimed map with no handoff session is a stale handoff" {
  map="$(new_map)"
  claim "$map"
  run_map_next "$map"
  equals "$(actions "$output")" "$(jq -cn --arg m "$map" '{action: "stale", ticket: $m, handoff: true}')"
}

# --- build ----------------------------------------------------------------------------

@test "build_epic on the map with tickets under it is the build" {
  map="$(new_map "- fog the spec settled")"
  spec="$(bd create --type=epic --title Spec --silent)"
  bd create --parent="$spec" --type=task --title slice --silent >/dev/null
  bd update "$map" --set-metadata "build_epic=$spec" >/dev/null
  run_map_next "$map"
  equals "$status" 0
  equals "$(actions "$output")" "$(jq -cn --arg s "$spec" '{action: "build", build_epic: $s}')"
}

@test "build_epic with no tickets under it yet is not the build" {
  map="$(new_map)"
  spec="$(bd create --type=epic --title Spec --silent)"
  claim "$map"
  live "$map-handoff"
  bd update "$map" --set-metadata "build_epic=$spec" >/dev/null
  run_map_next "$map"
  equals "$(kinds "$output")" "wait"
}

@test "--launch on a build starts nothing" {
  map="$(new_map)"
  spec="$(bd create --type=epic --title Spec --silent)"
  bd create --parent="$spec" --type=task --title slice --silent >/dev/null
  bd update "$map" --set-metadata "build_epic=$spec" >/dev/null
  run_map_next "$map" --launch
  equals "$(kinds "$output")" "build"
  equals "$(creates)" 0
}

# --- --launch ---------------------------------------------------------------------------

@test "--launch claims the ticket, then starts a claude session in a worktree named for it" {
  map="$(new_map)"
  t="$(ticket "$map" research)"
  run_map_next "$map" --launch
  equals "$status" 0
  equals "$(bd show "$t" --json | jq -r '.[0] | .status + " " + .assignee')" "in_progress tester"
  equals "$(cat "$ORCA_LOG")" "$(jq -cn --arg t "$t" --arg p "/wayfinder $map $t" \
    '["--name", $t, "--agent", "claude", "--prompt", $p, "--parent-worktree", "worktree:repo::/wt/chart", "--json"]')"
  equals "$(jq -c '.actions[0] | {result, worktree, parent}' <<<"$output")" \
    "$(jq -cn --arg t "$t" '{result: "launched", worktree: ("repo::/wt/" + $t), parent: "worktree:repo::/wt/chart"}')"
}

@test "--launch on a clear way claims the map and starts the handoff session" {
  map="$(new_map)"
  run_map_next "$map" --launch
  equals "$status" 0
  equals "$(bd show "$map" --json | jq -r '.[0].assignee')" tester
  equals "$(jq -r '.[1]' "$ORCA_LOG")" "$map-handoff"
  contains "$(jq -r '.[5]' "$ORCA_LOG")" "/to-spec-to-tickets"
  equals "$(jq -r '.actions[0].result' <<<"$output")" launched
}

@test "a failed session start hands the claim back and exits 1" {
  map="$(new_map)"
  t="$(ticket "$map" grilling)"
  export ORCA_CREATE_EXIT=3
  run_map_next "$map" --launch
  equals "$status" 1
  equals "$(jq -r '.actions[0].result' <<<"$output")" failed
  equals "$(bd show "$t" --json | jq -r '.[0] | .status + " " + (.assignee // "")')" "open "
}

@test "a ticket claimed between the read and the launch is skipped, not started twice" {
  map="$(new_map)"
  t="$(ticket "$map" grilling)"
  # bd wrapped so the claim map-next makes finds the ticket already taken by a
  # second run, which shares this run's actor.
  real_bd="$(command -v bd)"
  cat >"$STUB_BIN/bd" <<EOF
#!/bin/bash
case " \$* " in
*" --if-status open "*) "$real_bd" update "$t" --status in_progress --assignee tester >/dev/null ;;
esac
exec "$real_bd" "\$@"
EOF
  chmod +x "$STUB_BIN/bd"
  run_map_next "$map" --launch
  equals "$status" 0
  equals "$(jq -r '.actions[0].result' <<<"$output")" "claimed elsewhere"
  equals "$(creates)" 0
}

@test "a rerun after --launch waits on what it launched and starts nothing new" {
  map="$(new_map)"
  ticket "$map" research >/dev/null
  ticket "$map" grilling >/dev/null
  run_map_next "$map" --launch
  equals "$(creates)" 2
  run_map_next "$map" --launch
  equals "$status" 0
  equals "$(kinds "$output")" "wait wait"
  equals "$(creates)" 2
}

@test "two --launch runs at once start each ticket exactly once" {
  map="$(new_map)"
  ticket "$map" research >/dev/null
  ticket "$map" research >/dev/null
  "$MAP_NEXT" "$map" --launch >"$TMP/one" 2>&1 &
  "$MAP_NEXT" "$map" --launch >"$TMP/two" 2>&1 &
  wait
  equals "$(jq -r '.[1]' "$ORCA_LOG" | sort | uniq -d)" ""
  equals "$(creates)" 2
}

# --- the parent rule ------------------------------------------------------------------------

parent_used() {
  map="$(new_map)"
  ticket "$map" research >/dev/null
  run_map_next "$map" --launch "$@"
  jq -r '.[] | select(startswith("worktree:") or startswith("folder:") or startswith("branch:"))' "$ORCA_LOG"
}

@test "auto: a worktree whose parent is a worktree launches under that parent" {
  export ORCA_PARENT_KEY="worktree:repo::/wt/toolsmith"
  equals "$(parent_used)" "worktree:repo::/wt/toolsmith"
}

@test "auto: a worktree whose parent is a folder launches under itself" {
  export ORCA_PARENT_KEY="folder:home"
  equals "$(parent_used)" "worktree:repo::/wt/chart"
}

@test "auto: a worktree with no parent launches under itself" {
  equals "$(parent_used)" "worktree:repo::/wt/chart"
}

@test "--parent current launches under this worktree even when it has a worktree parent" {
  export ORCA_PARENT_KEY="worktree:repo::/wt/toolsmith"
  equals "$(parent_used --parent current)" "worktree:repo::/wt/chart"
}

@test "--parent parent launches under this worktree's parent, folder or not" {
  export ORCA_PARENT_KEY="folder:home"
  equals "$(parent_used --parent parent)" "folder:home"
}

@test "--parent parent with no parent fails before claiming anything" {
  map="$(new_map)"
  t="$(ticket "$map" research)"
  run_map_next "$map" --launch --parent parent
  equals "$status" 1
  contains "$stderr" "no parent"
  equals "$(bd show "$t" --json | jq -r '.[0].status')" open
}

@test "--parent <selector> passes the selector through" {
  equals "$(parent_used --parent branch:main)" "branch:main"
}

# --- the launch caps ----------------------------------------------------------------------

@test "every research ticket launches, but at most 2 that need Trevor; the rest hold" {
  map="$(new_map)"
  for _ in 1 2 3; do ticket "$map" research >/dev/null; done
  ticket "$map" grilling >/dev/null
  ticket "$map" prototype >/dev/null
  ticket "$map" task >/dev/null
  run_map_next "$map"
  equals "$(jq -r '[.actions[] | select(.action == "launch") | .type] | sort | join(" ")' <<<"$output")" \
    "grilling prototype research research research"
  equals "$(jq -r '[.actions[] | select(.action == "hold") | .type] | join(" ")' <<<"$output")" "task"
}

@test "a live session that needs Trevor takes one of the 2 slots" {
  map="$(new_map)"
  busy="$(ticket "$map" grilling)"
  claim "$busy"
  live "$busy"
  ticket "$map" grilling >/dev/null
  ticket "$map" grilling >/dev/null
  run_map_next "$map"
  equals "$(kinds "$output")" "wait launch hold"
}

@test "a stale claim does not take a slot" {
  map="$(new_map)"
  gone="$(ticket "$map" grilling)"
  claim "$gone"
  ticket "$map" grilling >/dev/null
  ticket "$map" grilling >/dev/null
  run_map_next "$map"
  equals "$(kinds "$output")" "stale launch launch"
}

@test "--max N overrides the cap on tickets that need Trevor" {
  map="$(new_map)"
  for _ in 1 2 3 4; do ticket "$map" grilling >/dev/null; done
  run_map_next "$map" --max 3
  equals "$(kinds "$output")" "launch launch launch hold"
}

@test "--max must be a whole number" {
  run_map_next mn-x --max lots
  equals "$status" 2
}

@test "--launch starts only the launches, not the held tickets" {
  map="$(new_map)"
  for _ in 1 2 3; do ticket "$map" grilling >/dev/null; done
  run_map_next "$map" --launch
  equals "$(creates)" 2
  equals "$(jq -r '[.actions[] | select(.action == "hold") | .result // "none"] | join(" ")' <<<"$output")" "none"
}

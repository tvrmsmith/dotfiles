load helpers/assert

HOOK="${BATS_TEST_DIRNAME}/../dot-claude/hooks/skill-arm.sh"
ORIGIN="git@github.com:example/a.git"
GUIDANCE='**Implementation phase**: ALWAYS load the `coding-standards:coding-standards` skill before writing or modifying code, and follow it.'
REVIEW_ONLY='**Implementation phase**: write or modify code without loading the `coding-standards:coding-standards` skill. The review step applies it.'

setup() {
  TMP="$(mktemp -d)"
  export XDG_STATE_HOME="$TMP/state"
  LOG="$XDG_STATE_HOME/coding-standards/arms.jsonl"
  unset NM_GATE
}
teardown() { rm -rf "$TMP"; }

# Makes a fixture repo at $TMP/$1 on branch $2 with origin $3 (default $ORIGIN).
make_repo() {
  local dir="$TMP/$1" branch="$2" origin="${3-$ORIGIN}"
  git init -q -b "$branch" "$dir"
  git -C "$dir" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  [ -z "$origin" ] || git -C "$dir" remote add origin "$origin"
}

# Pipes a SessionStart payload for session $1 at cwd $2 (extra jq fields in $3) into the hook.
start_out() {
  local extra="${3:-}"
  [ -n "$extra" ] || extra='{}'
  jq -n --arg s "$1" --arg c "$2" --argjson x "$extra" \
    '{session_id: $s, cwd: $c, hook_event_name: "SessionStart"} + $x' | bash "$HOOK"
}

ctx_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext'; }
last_arm() { tail -n 1 "$LOG" | jq -r '.arm'; }

@test "branch b19 hashes to guidance" {
  make_repo r b19
  out="$(start_out s1 "$TMP/r")"
  equals "$(ctx_of "$out")" "$GUIDANCE"
  equals "$(last_arm)" guidance
}

@test "branch b22 hashes to review-only" {
  make_repo r b22
  out="$(start_out s1 "$TMP/r")"
  equals "$(ctx_of "$out")" "$REVIEW_ONLY"
  equals "$(last_arm)" review-only
}

@test "branch other gets guidance and branch feature gets review-only" {
  make_repo a other
  make_repo b feature
  equals "$(ctx_of "$(start_out s1 "$TMP/a")")" "$GUIDANCE"
  equals "$(ctx_of "$(start_out s2 "$TMP/b")")" "$REVIEW_ONLY"
}

@test "no origin remote is unassigned with an empty repo" {
  make_repo r b22 ""
  out="$(start_out s1 "$TMP/r")"
  equals "$(ctx_of "$out")" "$GUIDANCE"
  equals "$(last_arm)" unassigned
  equals "$(tail -n 1 "$LOG" | jq -r '.repo')" ""
}

@test "detached HEAD is unassigned with an empty branch" {
  make_repo r b22
  git -C "$TMP/r" checkout -q --detach
  out="$(start_out s1 "$TMP/r")"
  equals "$(ctx_of "$out")" "$GUIDANCE"
  equals "$(last_arm)" unassigned
  equals "$(tail -n 1 "$LOG" | jq -r '.branch')" ""
}

@test "the branch origin/HEAD points at is unassigned" {
  make_repo r trunk
  git -C "$TMP/r" update-ref refs/remotes/origin/trunk HEAD
  git -C "$TMP/r" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  start_out s1 "$TMP/r" >/dev/null
  equals "$(last_arm)" unassigned
}

@test "main and master are default when origin/HEAD is unset" {
  make_repo a main
  make_repo b master
  start_out s1 "$TMP/a" >/dev/null
  equals "$(last_arm)" unassigned
  start_out s2 "$TMP/b" >/dev/null
  equals "$(last_arm)" unassigned
}

@test "a cwd outside any git repo is unassigned" {
  mkdir "$TMP/plain"
  out="$(start_out s1 "$TMP/plain")"
  equals "$(ctx_of "$out")" "$GUIDANCE"
  equals "$(last_arm)" unassigned
}

@test "NM_GATE=1 gets guidance on a review-only branch and writes no log" {
  make_repo r b22
  out="$(NM_GATE=1 start_out s1 "$TMP/r")"
  equals "$(ctx_of "$out")" "$GUIDANCE"
  [ ! -e "$LOG" ] || { echo "log written" >&2; exit 1; }
}

@test "a resumed session logs a second row with the same arm" {
  make_repo r b22
  first="$(start_out s1 "$TMP/r" '{"source":"startup"}')"
  second="$(start_out s1 "$TMP/r" '{"source":"resume"}')"
  equals "$(ctx_of "$first")" "$REVIEW_ONLY"
  equals "$(ctx_of "$second")" "$REVIEW_ONLY"
  equals "$(wc -l <"$LOG" | tr -d ' ')" 2
  equals "$(jq -r '.session_id + " " + .arm' "$LOG" | sort -u)" "s1 review-only"
}

@test "a second checkout with the same origin lands in the same arm" {
  make_repo r main
  git -C "$TMP/r" branch b22
  git -C "$TMP/r" checkout -q b22
  git clone -q "$TMP/r" "$TMP/clone"
  git -C "$TMP/clone" remote set-url origin "$ORIGIN"
  git -C "$TMP/clone" remote set-head origin -d
  equals "$(ctx_of "$(start_out s1 "$TMP/r")")" "$REVIEW_ONLY"
  equals "$(ctx_of "$(start_out s2 "$TMP/clone")")" "$REVIEW_ONLY"
}

@test "the log row has exactly the five keys in order with input-derived values" {
  make_repo r b22
  before="$(date +%s)"
  start_out sess-9 "$TMP/r" >/dev/null
  after="$(date +%s)"
  row="$(tail -n 1 "$LOG")"
  equals "$(printf '%s' "$row" | jq -c 'keys_unsorted')" '["ts","session_id","repo","branch","arm"]'
  equals "$(printf '%s' "$row" | jq -r '.ts | type')" number
  equals "$(printf '%s' "$row" | jq -r '[.ts == (.ts | floor), .ts >= '"$before"', .ts <= '"$after"'] | all')" true
  equals "$(printf '%s' "$row" | jq -r '.session_id')" sess-9
  equals "$(printf '%s' "$row" | jq -r '.repo')" "$ORIGIN"
  equals "$(printf '%s' "$row" | jq -r '.branch')" b22
}

@test "a double quote in the branch name still yields valid JSON" {
  make_repo r b22
  git -C "$TMP/r" checkout -q -b 'we"ird'
  start_out s1 "$TMP/r" >/dev/null
  equals "$(tail -n 1 "$LOG" | jq -r '.branch')" 'we"ird'
}

@test "an unwritable log location still emits the text and exits 0" {
  make_repo r b22
  # A directory where the log file goes fails the append, the last command in
  # the log group. A failed mkdir sits left of && and never trips set -e.
  mkdir -p "$LOG"
  run start_out s1 "$TMP/r"
  equals "$status" 0
  equals "$(ctx_of "$output")" "$REVIEW_ONLY"
}

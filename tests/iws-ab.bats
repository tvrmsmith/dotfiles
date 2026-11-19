bats_require_minimum_version 1.5.0
load helpers/assert

AB="${BATS_TEST_DIRNAME}/../dot-claude/skills/implement-with-subagents/ab.sh"

setup() {
  TMP="$(mktemp -d)"
  export IWS_AB_DIR="$TMP/iws" CLAUDE_PROJECTS_DIR="$TMP/projects"
  export NM_STATE_DB="$TMP/nm.sqlite" XDG_STATE_HOME="$TMP/state"
  export CLAUDE_CODE_SESSION_ID=sess-1
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  git init -q -b work "$TMP/repo"
  git -C "$TMP/repo" remote add origin git@github.com:example/repo.git
  cd "$TMP/repo" || exit 1
}
teardown() { rm -rf "$TMP"; }

# Writes one transcript line with message id $2, timestamp $3, output tokens $4 to file $1.
usage_line() {
  mkdir -p "$(dirname "$1")"
  jq -cn --arg id "$2" --arg ts "$3" --argjson o "$4" \
    '{timestamp:$ts, message:{id:$id, usage:{input_tokens:1, output_tokens:$o,
      cache_read_input_tokens:100, cache_creation_input_tokens:10}}}' >>"$1"
}

# Assigns slices "$2-1", "$2-2"... until one lands in arm $1, and prints its run id.
run_in() {
  local i out
  for i in $(seq 1 40); do
    out="$(bash "$AB" assign "$2-$i" 2>/dev/null)"
    if [ "$(jq -r .arm <<<"$out")" = "$1" ]; then jq -r .run <<<"$out"; return; fi
  done
  echo "no slice with prefix $2 hashed to $1" >&2
  exit 1
}

ready() { bash "$AB" finish --run "$1" --status ready --branch work --sha abc --killed "${2:-5}" "${@:3}"; }
last_row() { tail -n 1 "$IWS_AB_DIR/metrics.jsonl"; }

@test "slice id hashes to a stable arm, both arms reachable" {
  a1="$(bash "$AB" assign emr-1 | jq -r .arm)"
  a2="$(bash "$AB" assign emr-1 | jq -r .arm)"
  equals "$a1" "$a2"
  seen=""
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do seen+=" $(bash "$AB" assign "s-$i" | jq -r .arm)"; done
  contains "$seen" split
  contains "$seen" single
}

@test "a failed hash leaves the slice unassigned" {
  mkdir -p "$TMP/bin"
  printf '#!/bin/sh\nexit 1\n' >"$TMP/bin/shasum"
  chmod +x "$TMP/bin/shasum"
  out="$(PATH="$TMP/bin:$PATH" bash "$AB" assign emr-1)"
  equals "$(jq -c '{arm,assigned}' <<<"$out")" '{"arm":"split","assigned":false}'
  equals "$(tail -n 1 "$IWS_AB_DIR/starts.jsonl" | jq -r .arm)" unassigned
}

@test "free-text slice runs split and is logged unassigned" {
  out="$(bash "$AB" assign "")"
  equals "$(jq -c '{arm,assigned}' <<<"$out")" '{"arm":"split","assigned":false}'
  equals "$(tail -n 1 "$IWS_AB_DIR/starts.jsonl" | jq -r .arm)" unassigned
}

@test "start row records repo, session, unattended and coding-standards arm" {
  mkdir -p "$XDG_STATE_HOME/coding-standards"
  echo '{"session_id":"sess-1","arm":"review-only"}' >"$XDG_STATE_HOME/coding-standards/arms.jsonl"
  bash "$AB" assign emr-2 --unattended >/dev/null
  row="$(tail -n 1 "$IWS_AB_DIR/starts.jsonl")"
  equals "$(jq -c '{repo,session_id,unattended,cs_arm}' <<<"$row")" \
    '{"repo":"git@github.com:example/repo.git","session_id":"sess-1","unattended":true,"cs_arm":"review-only"}'
}

@test "finish sums deduped usage since start across parent and subagents" {
  r="$(bash "$AB" assign emr-3 | jq -r .run)"
  p="$CLAUDE_PROJECTS_DIR/-proj/sess-1.jsonl"
  usage_line "$p" before "2000-01-01T00:00:00.000Z" 999
  usage_line "$p" m1 "2999-01-01T00:00:00.000Z" 5
  usage_line "$p" m1 "2999-01-01T00:00:00.000Z" 5
  usage_line "$CLAUDE_PROJECTS_DIR/-proj/sess-1/subagents/agent-a.jsonl" m2 "2999-01-01T00:00:01.000Z" 7
  ready "$r" 4
  equals "$(last_row | jq -c '{tokens,experiment,mutation_kill_rate,sha}')" \
    '{"tokens":{"input":2,"output":12,"cache_read":200,"cache_write":20},"experiment":"iws-ab-v1","mutation_kill_rate":0.8,"sha":"abc"}'
}

@test "a run resumed under a new session sums both sessions once each" {
  r="$(bash "$AB" assign emr-4 | jq -r .run)"
  usage_line "$CLAUDE_PROJECTS_DIR/-proj/sess-1.jsonl" m1 "2999-01-01T00:00:00.000Z" 5
  usage_line "$CLAUDE_PROJECTS_DIR/-proj/sess-1.jsonl" shared "2999-01-01T00:00:01.000Z" 3
  usage_line "$CLAUDE_PROJECTS_DIR/-proj/sess-2.jsonl" shared "2999-01-01T00:00:01.000Z" 3
  usage_line "$CLAUDE_PROJECTS_DIR/-proj/sess-2.jsonl" m2 "2999-01-01T00:00:02.000Z" 7
  CLAUDE_CODE_SESSION_ID=sess-2 ready "$r"
  equals "$(last_row | jq -r .tokens.output)" 15
}

@test "finish takes the arm from the start row" {
  out="$(bash "$AB" assign emr-5)"
  bash "$AB" finish --run "$(jq -r .run <<<"$out")" --status aborted
  equals "$(last_row | jq -r .arm)" "$(jq -r .arm <<<"$out")"
}

@test "an aborted row carries no branch, sha or kill rate" {
  r="$(bash "$AB" assign emr-6 | jq -r .run)"
  bash "$AB" finish --run "$r" --status aborted
  equals "$(last_row | jq -c '{branch,sha,mutation_kill_rate}')" '{"branch":null,"sha":null,"mutation_kill_rate":null}'
}

@test "finish rejects each malformed call with its own reason" {
  r="$(bash "$AB" assign emr-7 | jq -r .run)"
  split="$(run_in split v)"
  check() {
    local want="$1"; shift
    run --separate-stderr bash "$AB" finish "$@"
    equals "$status" 2
    contains "$stderr" "$want"
  }
  check "no start row for run nope" --run nope --status aborted
  check "--status must be ready or aborted" --run "$r" --status "done"
  check "needs --branch, --sha and --killed" --run "$r" --status ready --branch work
  check "takes no --branch" --run "$r" --status aborted --sha abc
  check "--killed must be 0 to 5" --run "$r" --status ready --branch b --sha s --killed 6
  check "--redos must be a whole number" --run "$r" --status aborted --redos two
  check "--models must be a JSON object" --run "$r" --status aborted --models '{bad'
  check "only to a single-arm run" --run "$split" --status aborted --fit-fallback
  [ ! -f "$IWS_AB_DIR/metrics.jsonl" ] || { echo "a rejected call wrote a row" >&2; exit 1; }
}

@test "report prints each decision metric from known runs" {
  r1="$(run_in single a)"
  usage_line "$CLAUDE_PROJECTS_DIR/-proj/sess-1.jsonl" m1 "2999-01-01T00:00:00.000Z" 90
  ready "$r1" 3 --redos 1 --fanin-failures 2 --fit-fallback
  r2="$(run_in single b)"
  ready "$r2" 5 --redos 2
  out="$(bash "$AB" report)"
  contains "$out" "single: runs 2, ready 2, aborted 0"
  contains "$out" "mutation kill rate, mean:   0.8"
  contains "$out" "effective tokens, median:   111"
  contains "$out" "wall minutes, median:       null unattended, 0 attended"
  contains "$out" "redos, mean:                1.5"
  contains "$out" "fan-in failures, mean:      1"
  contains "$out" "fit fallbacks:              1"
  contains "$out" "by repo:                    repo 2"
}

@test "report takes escaped findings from the earliest later pipeline run" {
  sqlite3 "$NM_STATE_DB" "
    CREATE TABLE repos (id TEXT, working_path TEXT, upstream_url TEXT);
    CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, created_at INTEGER);
    CREATE TABLE step_results (id TEXT, run_id TEXT, step_name TEXT);
    CREATE TABLE step_rounds (id TEXT, step_result_id TEXT, round INTEGER, findings_json TEXT);
    INSERT INTO repos VALUES ('r', '/elsewhere', 'git@github.com:example/repo.git');
    INSERT INTO runs VALUES ('old', 'r', 'work', 1), ('new', 'r', 'work', 4000000000),
                            ('newer', 'r', 'work', 4100000000);
    INSERT INTO step_results VALUES ('s1', 'old', 'review'), ('s2', 'new', 'review'),
      ('s3', 'new', 'lint'), ('s4', 'new', 'test'), ('s5', 'newer', 'review');
    INSERT INTO step_rounds VALUES
      ('a', 's1', 1, '{\"findings\":[{\"severity\":\"error\"}]}'),
      ('b', 's2', 1, '{\"findings\":[{\"severity\":\"error\"},{\"severity\":\"warning\"},{\"severity\":\"info\"}]}'),
      ('c', 's2', 2, '{\"findings\":[{\"severity\":\"error\"}]}'),
      ('d', 's3', 1, '{\"findings\":[{\"severity\":\"error\"}]}'),
      ('e', 's4', 1, '{\"findings\":[{\"severity\":\"error\"}]}'),
      ('f', 's5', 1, '{\"findings\":[{\"severity\":\"error\"},{\"severity\":\"error\"},{\"severity\":\"error\"},{\"severity\":\"error\"},{\"severity\":\"error\"},{\"severity\":\"error\"},{\"severity\":\"error\"}]}');"
  r="$(bash "$AB" assign emr-8 | jq -r .run)"
  ready "$r"
  contains "$(bash "$AB" report)" "escaped findings, mean:     3 over 1 runs"
}

@test "report matches a pipeline run by repo path when the origin URL differs" {
  sqlite3 "$NM_STATE_DB" "
    CREATE TABLE repos (id TEXT, working_path TEXT, upstream_url TEXT);
    CREATE TABLE runs (id TEXT, repo_id TEXT, branch TEXT, created_at INTEGER);
    CREATE TABLE step_results (id TEXT, run_id TEXT, step_name TEXT);
    CREATE TABLE step_rounds (id TEXT, step_result_id TEXT, round INTEGER, findings_json TEXT);
    INSERT INTO repos VALUES ('r', '$(git rev-parse --show-toplevel)', 'https://example.com/other.git');
    INSERT INTO runs VALUES ('new', 'r', 'work', 4000000000);
    INSERT INTO step_results VALUES ('s', 'new', 'review');
    INSERT INTO step_rounds VALUES ('a', 's', 1, '{\"findings\":[{\"severity\":\"warning\"}]}');"
  r="$(bash "$AB" assign emr-9 | jq -r .run)"
  ready "$r"
  contains "$(bash "$AB" report)" "escaped findings, mean:     1 over 1 runs"
}

@test "a failing no-mistakes query warns instead of reading as no data" {
  echo "not a database" >"$NM_STATE_DB"
  r="$(bash "$AB" assign emr-10 | jq -r .run)"
  ready "$r"
  run --separate-stderr bash "$AB" report
  equals "$status" 0
  contains "$stderr" "no-mistakes query failed"
}

@test "report leaves out forced and unassigned runs" {
  r1="$(bash "$AB" assign "" | jq -r .run)"
  ready "$r1"
  ready "$(run_in single f)" 5 --forced
  ready "$(run_in single g)"
  out="$(bash "$AB" report)"
  contains "$out" "single: runs 1, ready 1"
  lacks "$out" unassigned
}

@test "a rerun slice counts once, as its newest row" {
  first="$(bash "$AB" assign emr-11 | jq -r .run)"
  bash "$AB" finish --run "$first" --status aborted
  sleep 1
  second="$(bash "$AB" assign emr-11 | jq -r .run)"
  ready "$second"
  contains "$(bash "$AB" report)" "runs 1, ready 1, aborted 0"
}

@test "finish announces the stopping point once both arms reach it" {
  # shellcheck disable=SC2030,SC2031  # each @test runs in its own subshell
  export IWS_AB_STOP_AT=1
  lacks "$(ready "$(run_in single h)")" "stopping point"
  contains "$(ready "$(run_in split i)")" "stopping point reached: both arms hold 1 ready slices"
}

@test "forced and aborted runs do not reach the stopping point" {
  # shellcheck disable=SC2030,SC2031  # each @test runs in its own subshell
  export IWS_AB_STOP_AT=1
  ready "$(run_in single j)" >/dev/null
  lacks "$(ready "$(run_in split k)" 5 --forced)" "stopping point"
  lacks "$(bash "$AB" finish --run "$(run_in split l)" --status aborted)" "stopping point"
}

@test "a missing session id or transcript is warned about, not silent" {
  unset CLAUDE_CODE_SESSION_ID
  run --separate-stderr bash "$AB" assign emr-12
  equals "$status" 0
  contains "$stderr" "CLAUDE_CODE_SESSION_ID is unset"
  r="$(jq -r .run <<<"$output")"
  run --separate-stderr bash "$AB" finish --run "$r" --status aborted
  equals "$status" 0
  contains "$stderr" "tokens recorded as null"
  equals "$(last_row | jq -r .tokens)" null
}

@test "a found transcript draws no warning" {
  r="$(bash "$AB" assign emr-13 | jq -r .run)"
  usage_line "$CLAUDE_PROJECTS_DIR/-proj/sess-1.jsonl" m1 "2999-01-01T00:00:00.000Z" 1
  run --separate-stderr bash "$AB" finish --run "$r" --status aborted
  is_empty "$stderr"
}

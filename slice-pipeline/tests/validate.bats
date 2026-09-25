# Each @test runs in its own subshell, so the stub knobs a test exports are
# meant to stay local to it.
# shellcheck disable=SC2030,SC2031
load helpers/assert
load helpers/stubs

# `slice-wave validate` drives a committed slice through no-mistakes to a
# green pull request and records what the run reported on that PR. Every
# external tool is a stub from helpers/stubs.bash, scripted per test.
HELPER="${BATS_TEST_DIRNAME}/../bin/slice-wave"

setup() {
  command -v jq >/dev/null || skip "no jq"

  # See slice-wave.bats: the developer's signing config would hang commits.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  STUB_BIN="$(mktemp -d)"
  export STUB_BIN
  export FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures/axi"
  install_stubs

  OLD_PATH="$PATH"
  export PATH="$STUB_BIN:$PATH"

  REPO="$(mktemp -d)"
  git -C "$REPO" init --quiet --initial-branch=slice/demo-1
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test \
    commit --quiet --allow-empty -m base
}

teardown() {
  export PATH="$OLD_PATH"
  rm -rf "$STUB_BIN" "$REPO"
}

validate() {
  ( cd "$REPO" && "$HELPER" validate --bead demo-1 --beads-dir /tmp/beads-demo "$@" )
}

@test "validate skips every tool and reports undelivered when verification did not pass" {
  rc=0; out="$(validate --verified false)" || rc=$?
  equals "$rc" 0
  equals "$(printf '%s' "$out" | jq -r .delivered)" false
  contains "$(printf '%s' "$out" | jq -r .reason)" "verification did not pass"
  is_empty "$(cat "$CALL_LOG")"
}

@test "validate exits 2 with the usage line when --verified is neither true nor false" {
  rc=0; out="$(validate --verified maybe 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
  is_empty "$(cat "$CALL_LOG")"
}

@test "validate exits 2 with the usage line when --verified is missing" {
  rc=0; out="$(validate 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
}

@test "validate exits 2 with the usage line when --verified has no value" {
  rc=0; out="$(validate --verified 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  contains "$(cat "$STUB_BIN/err")" "--verified needs a value"
}

@test "validate exits 2 with the usage line on an unknown flag" {
  rc=0; out="$(validate --verified true --force yes 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  contains "$(cat "$STUB_BIN/err")" "unknown flag --force"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
}

@test "validate delivers a checks-passed run and posts its findings record on the PR" {
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -c .)" \
    '{"delivered":true,"outcome":"checks-passed","pr_number":42,"pr_url":"https://github.com/owner/repo/pull/42","repo":"owner/repo","fix_rounds":1,"record_posted":true,"reason":""}'
  contains "$(cat "$CALL_LOG")" "$(printf 'gh\tpr comment https://github.com/owner/repo/pull/42 --body-file -')"
  lacks "$(cat "$CALL_LOG")" "pr list"
  lacks "$(cat "$CALL_LOG")" "repo view"
  body="$(cat "$STUB_BIN/pr-comment-body")"
  equals "$(printf '%s\n' "$body" | head -1)" "<!-- slice-pipeline:findings-record -->"
  contains "$body" "Drive mode: yes"
  contains "$body" "Outcome: checks-passed"
  contains "$body" "Fix rounds: 1"
  contains "$body" "Checked the rm exit status, per review-2"
  contains "$body" "Ask-user findings are not exposed under --yes; this record lists only what no-mistakes reports at the end of the run."
}

@test "validate records a failed run on its PR and reports the error as undelivered" {
  export NO_MISTAKES_RUN_SEQUENCE="$FIXTURES_DIR/failed.toon:1"
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -r .delivered)" false
  equals "$(printf '%s' "$out" | jq -r .outcome)" failed
  equals "$(printf '%s' "$out" | jq -r .pr_number)" 42
  equals "$(printf '%s' "$out" | jq -r .record_posted)" true
  contains "$(printf '%s' "$out" | jq -r .reason)" "ci: checks failed after 3 auto-fix attempts"
  contains "$(cat "$STUB_BIN/pr-comment-body")" "ci: checks failed after 3 auto-fix attempts"
  contains "$(cat "$STUB_BIN/pr-comment-body")" "Outcome: failed"
}

@test "validate reattaches without an intent when the drive's wait elapses" {
  export NO_MISTAKES_RUN_SEQUENCE="$FIXTURES_DIR/wait-elapsed.toon:1 $FIXTURES_DIR/checks-passed.toon:0"
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -r .delivered)" true
  runs="$(awk -F'\t' '$1 == "no-mistakes" { print $2 }' "$CALL_LOG")"
  equals "$(printf '%s\n' "$runs" | sed 's/ --intent .*//')" "$(printf 'axi run --yes\naxi run --yes')"
  contains "$(printf '%s\n' "$runs" | head -1)" " --intent Demo slice"
  lacks "$(printf '%s\n' "$runs" | tail -1)" "--intent"
}

@test "validate stops reattaching at its time limit and reports the drive as still running" {
  export SLICE_WAVE_DRIVE_LIMIT_SECONDS=0
  export NO_MISTAKES_RUN_SEQUENCE="$FIXTURES_DIR/wait-elapsed.toon:1 $FIXTURES_DIR/checks-passed.toon:0"
  export GH_PR_LIST_JSON='[{"number":7,"url":"https://github.com/owner/repo/pull/7"}]'
  rc=0; out="$(validate --verified true)" || rc=$?
  equals "$rc" 0
  equals "$(grep -c "$(printf '^no-mistakes\t')" "$CALL_LOG")" 1
  equals "$(printf '%s' "$out" | jq -r .delivered)" false
  contains "$(printf '%s' "$out" | jq -r .reason)" "the no-mistakes drive was still running"
  equals "$(printf '%s' "$out" | jq -r .record_posted)" true
  contains "$(cat "$STUB_BIN/pr-comment-body")" "the no-mistakes drive was still running"
}

@test "validate keeps reattaching while each reattach's wait elapses too" {
  export NO_MISTAKES_RUN_SEQUENCE="$FIXTURES_DIR/wait-elapsed.toon:1 $FIXTURES_DIR/wait-elapsed.toon:1 $FIXTURES_DIR/checks-passed.toon:0"
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -r .delivered)" true
  equals "$(grep -c "$(printf '^no-mistakes\taxi run --yes$')" "$CALL_LOG")" 2
}

@test "validate reads the last run it saw by id when a reattach finds the run already ended" {
  # Shaped by hand: no-mistakes prints no run block beside an elapsed error
  # today, so this pins what validate does if it ever does.
  { awk '/^outcome:/ { exit } { print }' "$FIXTURES_DIR/checks-passed.toon"
    echo 'error: wait of 8m0s elapsed while driving the run'
  } > "$STUB_BIN/elapsed-with-run.toon"
  export NO_MISTAKES_RUN_SEQUENCE="$STUB_BIN/elapsed-with-run.toon:1 $FIXTURES_DIR/intent-required-with-sync.toon:1"
  export NO_MISTAKES_STATUS_FIXTURE="$FIXTURES_DIR/checks-passed.toon"
  out="$(validate --verified true)"
  equals "$(awk -F'\t' '$1 == "no-mistakes" { last = $2 } END { print last }' "$CALL_LOG")" \
    "axi status --run 01RUNGREEN"
  equals "$(printf '%s' "$out" | jq -r .delivered)" true
}

@test "validate reads the branch's latest run when a reattach finds the run ended before any run block" {
  export NO_MISTAKES_RUN_SEQUENCE="$FIXTURES_DIR/wait-elapsed.toon:1 $FIXTURES_DIR/intent-required-with-sync.toon:1"
  export NO_MISTAKES_STATUS_FIXTURE="$FIXTURES_DIR/failed.toon"
  out="$(validate --verified true)"
  equals "$(awk -F'\t' '$1 == "no-mistakes" { last = $2 } END { print last }' "$CALL_LOG")" "axi status"
  equals "$(printf '%s' "$out" | jq -r .outcome)" failed
}

@test "validate finds the PR through gh when the run names none" {
  grep -v '^  pr: ' "$FIXTURES_DIR/checks-passed.toon" > "$STUB_BIN/no-pr.toon"
  export NO_MISTAKES_RUN_SEQUENCE="$STUB_BIN/no-pr.toon:0"
  export GH_PR_LIST_JSON='[{"number":7,"url":"https://github.com/owner/repo/pull/7"}]'
  out="$(validate --verified true)"
  contains "$(cat "$CALL_LOG")" "$(printf 'gh\tpr list --head slice/demo-1 --state open --json number,url -R owner/repo')"
  equals "$(printf '%s' "$out" | jq -r .pr_number)" 7
  equals "$(printf '%s' "$out" | jq -r .pr_url)" "https://github.com/owner/repo/pull/7"
  contains "$(cat "$CALL_LOG")" "$(printf 'gh\tpr comment https://github.com/owner/repo/pull/7 --body-file -')"
  equals "$(printf '%s' "$out" | jq -r .delivered)" true
}

@test "validate ignores a pr key outside the run block and falls back to gh" {
  { grep -v '^  pr: ' "$FIXTURES_DIR/checks-passed.toon"
    printf 'later:\n  pr: "https://github.com/x/y/pull/9"\n'
  } > "$STUB_BIN/stray-pr.toon"
  export NO_MISTAKES_RUN_SEQUENCE="$STUB_BIN/stray-pr.toon:0"
  export GH_PR_LIST_JSON='[{"number":7,"url":"https://github.com/owner/repo/pull/7"}]'
  out="$(validate --verified true)"
  contains "$(cat "$CALL_LOG")" "$(printf 'gh\tpr list --head slice/demo-1')"
  equals "$(printf '%s' "$out" | jq -c '{pr_number, pr_url, repo}')" \
    '{"pr_number":7,"pr_url":"https://github.com/owner/repo/pull/7","repo":"owner/repo"}'
  lacks "$(cat "$CALL_LOG")" "pull/9"
}

@test "validate posts no record and reports undelivered when neither the run nor gh names a PR" {
  grep -v '^  pr: ' "$FIXTURES_DIR/checks-passed.toon" > "$STUB_BIN/no-pr.toon"
  export NO_MISTAKES_RUN_SEQUENCE="$STUB_BIN/no-pr.toon:0"
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -r .pr_number)" 0
  equals "$(printf '%s' "$out" | jq -r .delivered)" false
  contains "$(printf '%s' "$out" | jq -r .reason)" "no open pull request"
  lacks "$(cat "$CALL_LOG")" "pr comment"
}

@test "validate refuses to guess between several open PRs for the branch" {
  grep -v '^  pr: ' "$FIXTURES_DIR/checks-passed.toon" > "$STUB_BIN/no-pr.toon"
  export NO_MISTAKES_RUN_SEQUENCE="$STUB_BIN/no-pr.toon:0"
  export GH_PR_LIST_JSON='[{"number":7,"url":"u7"},{"number":8,"url":"u8"}]'
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -r .pr_number)" 0
  contains "$(printf '%s' "$out" | jq -r .reason)" "2 open pull requests"
  lacks "$(cat "$CALL_LOG")" "pr comment"
}

@test "validate reports a gate --yes cannot pass as undelivered, without rerunning" {
  export NO_MISTAKES_RUN_SEQUENCE="$FIXTURES_DIR/gate-protected.toon:0"
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -r .delivered)" false
  contains "$(printf '%s' "$out" | jq -r .reason)" "lint gate: Automatic commit refused for a protected path"
  equals "$(grep -c "$(printf '^no-mistakes\t')" "$CALL_LOG")" 1
  lacks "$(cat "$CALL_LOG")" "rerun"
}

@test "validate names an outcome short of checks-passed as the reason it did not deliver" {
  sed 's/^outcome: checks-passed$/outcome: passed-with-skips/' "$FIXTURES_DIR/checks-passed.toon" > "$STUB_BIN/skips.toon"
  export NO_MISTAKES_RUN_SEQUENCE="$STUB_BIN/skips.toon:0"
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -r .delivered)" false
  equals "$(printf '%s' "$out" | jq -r .record_posted)" true
  contains "$(printf '%s' "$out" | jq -r .reason)" "no-mistakes ended passed-with-skips, not checks-passed or passed"
}

@test "validate names output with no outcome, gate or error as the reason it did not deliver" {
  printf 'daemon crashed\n' > "$STUB_BIN/garbage.toon"
  export NO_MISTAKES_RUN_SEQUENCE="$STUB_BIN/garbage.toon:1"
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -r .delivered)" false
  contains "$(printf '%s' "$out" | jq -r .reason)" "no-mistakes reported no outcome: daemon crashed"
}

@test "validate reports undelivered when gh refuses the findings record comment" {
  export GH_PR_COMMENT_EXIT=1
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -r .record_posted)" false
  equals "$(printf '%s' "$out" | jq -r .delivered)" false
  contains "$(printf '%s' "$out" | jq -r .reason)" "cannot post the findings record on pull request https://github.com/owner/repo/pull/42"
}

@test "validate reports undelivered without driving no-mistakes when bd cannot show the bead" {
  export BD_EXIT_CODE=1
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -r .delivered)" false
  contains "$(printf '%s' "$out" | jq -r .reason)" "bd show"
  lacks "$(cat "$CALL_LOG")" "no-mistakes"
}

@test "validate reports undelivered without driving no-mistakes when the bead has no intent text" {
  export BD_SHOW_JSON='[{"id":"demo-1","title":"","description":null,"acceptance_criteria":"","notes":""}]'
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -r .delivered)" false
  contains "$(printf '%s' "$out" | jq -r .reason)" "bead demo-1 has no title, description, design, acceptance criteria or notes"
  lacks "$(cat "$CALL_LOG")" "no-mistakes"
}

@test "validate passes the bead's title and acceptance criteria to no-mistakes as the intent" {
  export BD_SHOW_JSON='[{"id":"demo-1","title":"Greet the user","description":"","acceptance_criteria":"Prints hello on start","notes":null}]'
  validate --verified true >/dev/null
  # The intent spans lines, so the call's entry runs until the next tool's line.
  run_line="$(awk '/^no-mistakes\taxi run --yes --intent/ { p = 1; print; next } /^(bd|gh|no-mistakes)\t/ { p = 0 } p' "$CALL_LOG")"
  contains "$run_line" "Greet the user"
  contains "$run_line" "Prints hello on start"
  contains "$(cat "$BD_LOG")" "$(printf '/tmp/beads-demo\tshow demo-1 --json')"
}

@test "validate reports undelivered and posts nothing when gh cannot name the repository" {
  grep -v '^  pr: ' "$FIXTURES_DIR/checks-passed.toon" > "$STUB_BIN/no-pr.toon"
  export NO_MISTAKES_RUN_SEQUENCE="$STUB_BIN/no-pr.toon:0"
  export GH_EXIT_CODE=1
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -r .delivered)" false
  equals "$(printf '%s' "$out" | jq -r .repo)" ""
  contains "$(printf '%s' "$out" | jq -r .reason)" "gh repo view named no repository"
  lacks "$(cat "$CALL_LOG")" "pr comment"
}

@test "validate delivers a run the branch's status reports passed after a reattach found it ended" {
  # A terminal run's status maps RunCompleted to `passed`, never checks-passed.
  sed 's/^outcome: checks-passed$/outcome: passed/; s/^  status: running$/  status: completed/' \
    "$FIXTURES_DIR/checks-passed.toon" > "$STUB_BIN/status-passed.toon"
  export NO_MISTAKES_RUN_SEQUENCE="$FIXTURES_DIR/wait-elapsed.toon:1 $FIXTURES_DIR/intent-required-with-sync.toon:1"
  export NO_MISTAKES_STATUS_FIXTURE="$STUB_BIN/status-passed.toon"
  out="$(validate --verified true)"
  equals "$(awk -F'\t' '$1 == "no-mistakes" { print $2 }' "$CALL_LOG" | tail -1)" "axi status"
  equals "$(printf '%s' "$out" | jq -r .outcome)" passed
  equals "$(printf '%s' "$out" | jq -r .pr_number)" 42
  equals "$(printf '%s' "$out" | jq -r .delivered)" true
  is_empty "$(printf '%s' "$out" | jq -r .reason)"
}

@test "validate posts on the run's PR and names its repo when gh's default repo differs" {
  sed 's#^  pr: .*#  pr: "https://github.com/fork/other/pull/42"#' \
    "$FIXTURES_DIR/checks-passed.toon" > "$STUB_BIN/fork-pr.toon"
  export NO_MISTAKES_RUN_SEQUENCE="$STUB_BIN/fork-pr.toon:0"
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -c '{repo, pr_number, delivered}')" '{"repo":"fork/other","pr_number":42,"delivered":true}'
  contains "$(cat "$CALL_LOG")" "$(printf 'gh\tpr comment https://github.com/fork/other/pull/42 --body-file -')"
  lacks "$(cat "$CALL_LOG")" "repo view"
}

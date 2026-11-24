# Each @test runs in its own subshell, so the stub knobs a test exports are
# meant to stay local to it.
# shellcheck disable=SC2030,SC2031
load helpers/assert
load helpers/stubs

# slice-wave-validator-imr-ship, the external adapter for the imr-ship
# validator, driven through slice-wave's claim and validate as the pipeline
# runs it. imr is a stub defined here; every other tool comes from
# helpers/stubs.bash.
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
  unset IMR_EXIT IMR_OUTPUT IMR_SLEEP
  # Default: an `imr pr ship` that opens its pull request and exits 0.
  # IMR_OUTPUT replaces what it prints, IMR_EXIT its exit status, and
  # IMR_SLEEP makes it run that many seconds first, exec'd so a signal to
  # the stub reaches the sleep.
  cat > "$STUB_BIN/imr" <<'STUB'
#!/bin/bash
printf 'imr\t%s\n' "$*" >> "$CALL_LOG"
printf '%s\n' "${IMR_OUTPUT:-$(printf '▶ open\n✓ open (1m2s)')}"
[ -z "${IMR_SLEEP:-}" ] || exec sleep "$IMR_SLEEP"
exit "${IMR_EXIT:-0}"
STUB
  chmod +x "$STUB_BIN/imr"
  # No run may read the machine's real repos.json.
  export XDG_CONFIG_HOME="$STUB_BIN/config"
  mkdir -p "$XDG_CONFIG_HOME/slice-pipeline"
  printf '%s\n' '{"owner/repo":{"validator":"imr-ship"}}' > "$XDG_CONFIG_HOME/slice-pipeline/repos.json"

  OLD_PATH="$PATH"
  export PATH="$STUB_BIN:${BATS_TEST_DIRNAME}/../bin:$PATH"

  REPO="$(mktemp -d)"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test \
    commit --quiet --allow-empty -m base
  ORIGIN="$(mktemp -d)"
  git init --quiet --bare "$ORIGIN"
  git -C "$REPO" remote add origin "$ORIGIN"
}

teardown() {
  export PATH="$OLD_PATH"
  rm -rf "$STUB_BIN" "$REPO" "$ORIGIN"
}

validate() {
  git -C "$REPO" checkout --quiet -b slice/demo-1
  ( cd "$REPO" && "$HELPER" validate --bead demo-1 --beads-dir /tmp/beads-demo "$@" )
}

@test "claim on an imr-ship target checks imr instead of no-mistakes and claims the bead" {
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "/tmp/beads-foo" )"
  equals "$(printf '%s' "$out" | jq -r .branch)" "slice/foo"
  contains "$(cat "$BD_LOG")" "$(printf '%s\t%s' "/tmp/beads-foo" "update foo --claim")"
  lacks "$(cat "$CALL_LOG")" "no-mistakes"
}

@test "claim exits 1 without touching the tracker when an imr-ship target has no imr on PATH" {
  rm "$STUB_BIN/imr"
  no_imr_path="$STUB_BIN"
  IFS=: read -ra dirs <<<"$OLD_PATH:${BATS_TEST_DIRNAME}/../bin"
  for dir in "${dirs[@]}"; do
    [ -x "$dir/imr" ] || no_imr_path="$no_imr_path:$dir"
  done
  rc=0
  out="$( cd "$REPO" && PATH="$no_imr_path" "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "no imr is on PATH"
  is_empty "$(cat "$BD_LOG")"
  equals "$(git -C "$REPO" symbolic-ref --short HEAD)" "main"
}

@test "validate delivers an imr-ship target once imr pr ship opens its pull request" {
  export GH_PR_LIST_JSON='[{"number":42,"url":"https://github.com/owner/repo/pull/42"}]'
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -c .)" \
    '{"delivered":true,"outcome":"opened","pr_number":42,"pr_url":"https://github.com/owner/repo/pull/42","repo":"owner/repo","fix_rounds":0,"record_posted":true,"reason":""}'
  contains "$(cat "$CALL_LOG")" "$(printf 'imr\tpr ship --autofix-review --plain --intent Demo slice')"
  lacks "$(cat "$CALL_LOG")" "no-mistakes"
  body="$(cat "$STUB_BIN/pr-comment-body")"
  equals "$(printf '%s\n' "$body" | head -1)" "<!-- slice-pipeline:findings-record -->"
  contains "$body" "Validator: imr pr ship --autofix-review"
  contains "$body" "Outcome: opened"
}

@test "validate reports a halted imr pr ship as undelivered and names the line it stopped on and how to resume" {
  export IMR_EXIT=1
  export IMR_OUTPUT="$(printf '▶ review\n⏸ review: 2 findings need a decision\nstopped: halted at gate "review", asking: fix or file?')"
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -r .delivered)" false
  equals "$(printf '%s' "$out" | jq -r .outcome)" halted
  reason="$(printf '%s' "$out" | jq -r .reason)"
  contains "$reason" "imr pr ship exited 1 on 'stopped: halted at gate \"review\", asking: fix or file?'"
  contains "$reason" "imr pr ship --resume --autofix-review"
  contains "$reason" "no open pull request"
}

@test "validate records a halted imr pr ship on a pull request it already opened" {
  export GH_PR_LIST_JSON='[{"number":42,"url":"https://github.com/owner/repo/pull/42"}]'
  export IMR_EXIT=1
  export IMR_OUTPUT='✗ open: title check failed'
  out="$(validate --verified true)"
  equals "$(printf '%s' "$out" | jq -r .delivered)" false
  equals "$(printf '%s' "$out" | jq -r .record_posted)" true
  contains "$(cat "$STUB_BIN/pr-comment-body")" "Stopped on: ✗ open: title check failed"
}

@test "validate stops an imr pr ship still running at its time limit and reports it halted" {
  export IMR_SLEEP=30 SLICE_WAVE_DRIVE_LIMIT_SECONDS=2 SLICE_WAVE_VALIDATOR_POLL_SECONDS=2
  SECONDS=0
  out="$(validate --verified true)"
  [ "$SECONDS" -lt 20 ] || { echo "validate waited out the ship instead of stopping it" >&2; exit 1; }
  equals "$(printf '%s' "$out" | jq -r .delivered)" false
  equals "$(printf '%s' "$out" | jq -r .outcome)" halted
  contains "$(printf '%s' "$out" | jq -r .reason)" "still running when validate reached its time limit"
  contains "$(printf '%s' "$out" | jq -r .reason)" "imr pr ship --resume --autofix-review"
}

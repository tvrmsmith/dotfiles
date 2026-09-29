# require_e2e_sandbox is the guard e2e.bats' setup_file calls before a run
# touches a real target, so its gh calls and the clone's committed HEAD are
# pinned here against the gh stub and a local bare origin, the same fixtures
# e2e-cleanup.bats uses.
load helpers/assert
load helpers/stubs
load helpers/e2e-sandbox

setup() {
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  STUB_BIN="$(mktemp -d)"
  export STUB_BIN
  install_stubs
  OLD_PATH="$PATH"
  export PATH="$STUB_BIN:$PATH"

  ORIGIN="$STUB_BIN/origin.git"
  CLONE="$STUB_BIN/clone"
  git init --quiet --bare --initial-branch=main "$ORIGIN"
  git clone --quiet "$ORIGIN" "$CLONE" 2>/dev/null
  git -C "$CLONE" -c user.email=t@example.com -c user.name=Test \
    commit --quiet --allow-empty -m base
}

teardown() {
  export PATH="$OLD_PATH"
  rm -rf "$STUB_BIN"
}

commit_marker() {
  : > "$CLONE/.slice-e2e-sandbox"
  git -C "$CLONE" add .slice-e2e-sandbox
  git -C "$CLONE" -c user.email=t@example.com -c user.name=Test \
    commit --quiet -m marker
}

@test "marker committed in the clone and gh confirms the forge carries it" {
  commit_marker
  rc=0; require_e2e_sandbox owner/sandbox "$CLONE" 2>"$STUB_BIN/err" || rc=$?
  equals "$rc" 0
  is_empty "$(cat "$STUB_BIN/err")"
  contains "$(cat "$CALL_LOG")" "$(printf 'gh\tapi repos/owner/sandbox/contents/.slice-e2e-sandbox')"
}

@test "clone has no marker at all: gh is never called" {
  rc=0; require_e2e_sandbox owner/sandbox "$CLONE" 2>"$STUB_BIN/err" || rc=$?
  equals "$rc" 1
  contains "$(cat "$STUB_BIN/err")" "owner/sandbox"
  contains "$(cat "$STUB_BIN/err")" ".slice-e2e-sandbox"
  is_empty "$(cat "$CALL_LOG")"
}

@test "marker exists in the working tree but is untracked: it does not satisfy the check" {
  : > "$CLONE/.slice-e2e-sandbox"
  rc=0; require_e2e_sandbox owner/sandbox "$CLONE" 2>"$STUB_BIN/err" || rc=$?
  equals "$rc" 1
  contains "$(cat "$STUB_BIN/err")" "no committed .slice-e2e-sandbox"
  is_empty "$(cat "$CALL_LOG")"
}

@test "marker committed in the clone but gh fails on the forge: the refusal carries gh's own output" {
  commit_marker
  export GH_EXIT_CODE=1
  rc=0; require_e2e_sandbox owner/sandbox "$CLONE" 2>"$STUB_BIN/err" || rc=$?
  equals "$rc" 1
  contains "$(cat "$STUB_BIN/err")" "cannot confirm owner/sandbox carries .slice-e2e-sandbox on its default branch"
  contains "$(cat "$STUB_BIN/err")" "gh said: gh: stub configured to fail"
  contains "$(cat "$CALL_LOG")" "$(printf 'gh\tapi repos/owner/sandbox/contents/.slice-e2e-sandbox')"
}

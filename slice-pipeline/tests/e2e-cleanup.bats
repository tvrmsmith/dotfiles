# Each @test runs in its own subshell, so the stub knobs a test exports are
# meant to stay local to it.
# shellcheck disable=SC2030,SC2031
load helpers/assert
load helpers/stubs
load helpers/e2e-cleanup

# e2e.bats' teardown acts on a real GitHub repository, so what it closes and
# deletes is pinned here against the gh stub and a local bare origin.

setup() {
  command -v jq >/dev/null || skip "no jq"
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
  git -C "$CLONE" push --quiet origin HEAD:main HEAD:slice/demo-1 2>/dev/null
}

teardown() {
  export PATH="$OLD_PATH"
  rm -rf "$STUB_BIN"
}

@test "cleanup with an empty branch calls gh for nothing and deletes no branch" {
  export GH_PR_LIST_JSON='[{"number":14,"headRefName":"commit-to-pr"}]'
  close_slice_branch owner/repo "" "$CLONE" 2>"$STUB_BIN/err"
  is_empty "$(cat "$CALL_LOG")"
  contains "$(cat "$STUB_BIN/err")" "no slice branch"
  git -C "$CLONE" ls-remote --exit-code origin refs/heads/main >/dev/null
}

@test "cleanup of a branch outside slice/ calls gh for nothing and deletes no branch" {
  close_slice_branch owner/repo main "$CLONE" 2>/dev/null
  is_empty "$(cat "$CALL_LOG")"
  git -C "$CLONE" ls-remote --exit-code origin refs/heads/main >/dev/null
}

@test "cleanup closes only the open pull requests whose head is the slice branch, then deletes it" {
  export GH_PR_LIST_JSON='[{"number":7,"headRefName":"slice/demo-1"},{"number":14,"headRefName":"commit-to-pr"}]'
  close_slice_branch owner/repo slice/demo-1 "$CLONE"
  contains "$(cat "$CALL_LOG")" "$(printf 'gh\tpr list -R owner/repo --head slice/demo-1 --state open')"
  equals "$(grep -c "$(printf '^gh\tpr close')" "$CALL_LOG")" 1
  contains "$(cat "$CALL_LOG")" "$(printf 'gh\tpr close 7 -R owner/repo')"
  rc=0; git -C "$CLONE" ls-remote --exit-code origin refs/heads/slice/demo-1 >/dev/null || rc=$?
  equals "$rc" 2
  git -C "$CLONE" ls-remote --exit-code origin refs/heads/main >/dev/null
}

@test "cleanup closes nothing but still deletes the branch when gh cannot list pull requests" {
  export GH_PR_LIST_JSON='not json'
  close_slice_branch owner/repo slice/demo-1 "$CLONE" 2>"$STUB_BIN/err"
  lacks "$(cat "$CALL_LOG")" "pr close"
  contains "$(cat "$STUB_BIN/err")" "cannot list open pull requests for slice/demo-1"
  rc=0; git -C "$CLONE" ls-remote --exit-code origin refs/heads/slice/demo-1 >/dev/null || rc=$?
  equals "$rc" 2
}

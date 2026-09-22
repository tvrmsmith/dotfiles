load helpers/assert

# slice-wave is the only test seam the Archon slice pipeline has: the workflow
# YAML shells out to it directly, with no seam of its own, so every
# non-trivial rule lives here instead of behind a workflow run.
HELPER="${BATS_TEST_DIRNAME}/../bin/slice-wave"

setup() {
  command -v jq >/dev/null || skip "no jq"

  STUB_BIN="$(mktemp -d)"
  export BD_LOG="$STUB_BIN/bd.log"
  : > "$BD_LOG"

  # Logs argv and BEADS_DIR so a test can assert on the call the module made,
  # and returns whatever exit code the test set beforehand.
  cat > "$STUB_BIN/bd" <<'EOF'
#!/bin/bash
printf '%s\t%s\n' "${BEADS_DIR:-}" "$*" >> "$BD_LOG"
exit "${BD_EXIT_CODE:-0}"
EOF
  chmod +x "$STUB_BIN/bd"

  OLD_PATH="$PATH"
  export PATH="$STUB_BIN:$PATH"
  unset BD_EXIT_CODE

  REPO="$(mktemp -d)"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test \
    commit --quiet --allow-empty -m base
}

teardown() {
  export PATH="$OLD_PATH"
  rm -rf "$STUB_BIN" "$REPO"
}

@test "an unknown subcommand prints the usage line to stderr and exits 2" {
  rc=0; out="$("$HELPER" resurrect --bead foo 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave <branch-name|claim|release|verify-commit>"
}

@test "no subcommand at all prints the usage line to stderr and exits 2" {
  rc=0; out="$("$HELPER" 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave"
}

@test "branch-name derives a branch from a bead id" {
  out="$("$HELPER" branch-name dotfiles-co3.4)"
  equals "$out" "slice/dotfiles-co3.4"
}

@test "branch-name lowercases and replaces characters git would refuse" {
  out="$("$HELPER" branch-name "Foo Bar/Baz")"
  equals "$out" "slice/foo-bar-baz"
}

@test "branch-name exits 2 on a bead id that sanitises away to nothing" {
  rc=0; out="$("$HELPER" branch-name ".." 2>/dev/null)" || rc=$?
  is_empty "$out"
  equals "$rc" 2
}

@test "branch-name exits 2 on a name git itself rejects" {
  rc=0; out="$("$HELPER" branch-name "a.lock" 2>/dev/null)" || rc=$?
  is_empty "$out"
  equals "$rc" 2
}

@test "branch-name trims a trailing dot git would refuse at the end of a ref" {
  out="$("$HELPER" branch-name "foo.")"
  equals "$out" "slice/foo"
}

@test "claim exits 2 without touching the tracker when a flag is missing" {
  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --bead foo 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "claim needs --bead and --beads-dir"
  is_empty "$(cat "$BD_LOG")"
}

@test "claim puts the worktree on the derived branch when it is not already there" {
  ( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" ) >/dev/null
  branch="$(git -C "$REPO" symbolic-ref --short HEAD)"
  equals "$branch" "slice/foo"
}

@test "claim leaves the worktree alone when it is already on the derived branch" {
  git -C "$REPO" switch --quiet -c slice/foo
  sha_before="$(git -C "$REPO" rev-parse HEAD)"
  ( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" ) >/dev/null
  branch="$(git -C "$REPO" symbolic-ref --short HEAD)"
  equals "$branch" "slice/foo"
  equals "$(git -C "$REPO" rev-parse HEAD)" "$sha_before"
}

@test "claim switches to the derived branch when it already exists" {
  git -C "$REPO" branch slice/foo
  ( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" ) >/dev/null
  branch="$(git -C "$REPO" symbolic-ref --short HEAD)"
  equals "$branch" "slice/foo"
}

@test "claim claims the bead through the tracker with the beads directory supplied" {
  ( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "/tmp/beads-foo" ) >/dev/null
  contains "$(cat "$BD_LOG")" "$(printf '%s\t%s' "/tmp/beads-foo" "update foo --claim")"
}

@test "claim emits the bead, the beads directory and the branch name as one JSON object" {
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "/tmp/beads-foo" )"
  equals "$(printf '%s' "$out" | jq -c .)" \
    '{"bead":"foo","beads_dir":"/tmp/beads-foo","branch":"slice/foo"}'
}

# shellcheck disable=SC2030
@test "claim exits non-zero and writes nothing to stdout when the tracker refuses the claim" {
  export BD_EXIT_CODE=1
  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" 2>/dev/null )" || rc=$?
  is_empty "$out"
  [ "$rc" -ne 0 ] || { echo "expected non-zero exit, got 0" >&2; exit 1; }
}

@test "claim does not claim the bead when it cannot put the worktree on the branch" {
  # A dirty tracked file that slice/foo deletes makes git switch refuse rather
  # than discard the uncommitted change.
  echo "base" > "$REPO/tracked"
  git -C "$REPO" add tracked
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add tracked"
  git -C "$REPO" switch --quiet -c slice/foo
  git -C "$REPO" rm -q tracked
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "remove tracked"
  git -C "$REPO" switch --quiet main
  echo "dirty" > "$REPO/tracked"

  rc=0
  ( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" ) >/dev/null 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected non-zero exit, got 0" >&2; exit 1; }
  is_empty "$(cat "$BD_LOG")"
}

@test "release clears the assignee and returns the status to open" {
  out="$("$HELPER" release --bead foo --beads-dir "/tmp/beads-foo")"
  equals "$out" '{"released":true}'
  contains "$(cat "$BD_LOG")" "$(printf '%s\t%s' "/tmp/beads-foo" 'update foo -a  -s open')"
}

@test "release exits 0 on a bead that is already unassigned and open" {
  rc=0
  out="$("$HELPER" release --bead foo --beads-dir "$STUB_BIN")" || rc=$?
  equals "$rc" 0
  equals "$out" '{"released":true}'
}

@test "release exits 2 without touching the tracker when a flag is missing" {
  rc=0; out="$("$HELPER" release --bead foo 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "release needs --bead and --beads-dir"
  is_empty "$(cat "$BD_LOG")"
}

# shellcheck disable=SC2031
@test "release exits non-zero and writes nothing to stdout when the tracker refuses" {
  export BD_EXIT_CODE=1
  rc=0; out="$("$HELPER" release --bead foo --beads-dir "$STUB_BIN" 2>"$STUB_BIN/err")" || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected non-zero exit, got 0" >&2; exit 1; }
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "tracker refused to release foo"
}

@test "verify-commit reports verified for a commit on the branch that touches a test file" {
  git -C "$REPO" switch --quiet -c slice/foo
  echo "@test x {}" > "$REPO/thing.bats"
  git -C "$REPO" add thing.bats
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add test"
  expected_sha="$(git -C "$REPO" rev-parse slice/foo)"

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo --base main )"
  equals "$(printf '%s' "$out" | jq -c .)" \
    "$(jq -nc --arg sha "$expected_sha" \
      '{verified:true,committed:true,tests_touched:true,branch:"slice/foo",sha:$sha,reason:""}')"
}

@test "verify-commit prefers an explicit --base over origin/HEAD" {
  # origin/HEAD is set to the branch tip, so whichever ref wins decides the
  # verdict: against main there is a commit, against origin/HEAD there is none.
  git -C "$REPO" switch --quiet -c slice/foo
  echo "@test x {}" > "$REPO/thing.bats"
  git -C "$REPO" add thing.bats
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add test"
  git -C "$REPO" update-ref refs/remotes/origin/HEAD "$(git -C "$REPO" rev-parse slice/foo)"

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo --base main )"
  equals "$(printf '%s' "$out" | jq -r '.committed')" "true"
  equals "$(printf '%s' "$out" | jq -r '.verified')" "true"
}

@test "verify-commit reports not committed when the branch has nothing beyond its base" {
  git -C "$REPO" branch slice/foo

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo --base main )"
  equals "$(printf '%s' "$out" | jq -c .)" \
    '{"verified":false,"committed":false,"tests_touched":false,"branch":"slice/foo","sha":"","reason":"no commit on slice/foo beyond main"}'
}

@test "verify-commit reports not committed when the derived branch does not exist" {
  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo --base main )"
  equals "$(printf '%s' "$out" | jq -c .)" \
    '{"verified":false,"committed":false,"tests_touched":false,"branch":"slice/foo","sha":"","reason":"no branch slice/foo"}'
}

@test "verify-commit counts a plain file under a tests directory as a test file" {
  # Every other verified case here is decided by the basename arm, so this is
  # the only one that reaches the path-component arm.
  git -C "$REPO" switch --quiet -c slice/foo
  mkdir -p "$REPO/docs/tests"
  echo "notes" > "$REPO/docs/tests/notes.txt"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add notes"

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo --base main )"
  equals "$(printf '%s' "$out" | jq -r '.tests_touched')" "true"
  equals "$(printf '%s' "$out" | jq -r '.verified')" "true"
}

@test "verify-commit matches a whole path component, not a word inside one" {
  # 'my tests' is not a tests directory. Matching the path as one string is
  # what tells the two apart: splitting the path into words to compare them
  # turns this component into a bare 'tests' and reads the file as a test.
  git -C "$REPO" switch --quiet -c slice/foo
  mkdir -p "$REPO/my tests"
  echo "notes" > "$REPO/my tests/notes.txt"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add notes"

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo --base main )"
  equals "$(printf '%s' "$out" | jq -r '.tests_touched')" "false"
  equals "$(printf '%s' "$out" | jq -r '.verified')" "false"
}

@test "verify-commit reports committed but not verified when no test file changed" {
  git -C "$REPO" switch --quiet -c slice/foo
  echo "code" > "$REPO/thing.sh"
  git -C "$REPO" add thing.sh
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add code"
  expected_sha="$(git -C "$REPO" rev-parse slice/foo)"

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo --base main )"
  equals "$(printf '%s' "$out" | jq -c .)" \
    "$(jq -nc --arg sha "$expected_sha" \
      '{verified:false,committed:true,tests_touched:false,branch:"slice/foo",sha:$sha,reason:"no test file in the commits on slice/foo"}')"
}

@test "verify-commit finds a test file in a diff too wide for the pipe buffer" {
  # The test file sorts first, so a reader that stops at the first match leaves
  # git writing into a closed pipe. Under pipefail the resulting SIGPIPE reads
  # back as "no test file changed", but only once the path list outgrows the
  # 64KB buffer, which is why the narrow cases above cannot catch it.
  git -C "$REPO" switch --quiet -c slice/foo
  mkdir -p "$REPO/tests" "$REPO/z"
  echo "@test x {}" > "$REPO/tests/thing.bats"
  for i in $(seq 1 3000); do
    echo "$i" > "$REPO/z/a-fairly-long-file-name-to-fill-the-pipe-buffer-$i.txt"
  done
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "wide"

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo --base main )"
  equals "$(printf '%s' "$out" | jq -r '.tests_touched')" "true"
  equals "$(printf '%s' "$out" | jq -r '.verified')" "true"
}

@test "verify-commit exits 0 on every verdict" {
  # no branch, no base, and a false verdict all still exit 0: the workflow
  # node reads the verdict from verified, and a non-zero exit would fail the
  # node and throw the artifacts away.
  rc=0; ( cd "$REPO" && "$HELPER" verify-commit --bead foo --base main ) >/dev/null || rc=$?
  equals "$rc" 0

  rc=0; ( cd "$REPO" && "$HELPER" verify-commit --bead foo --base nonexistent-ref ) >/dev/null || rc=$?
  equals "$rc" 0

  git -C "$REPO" switch --quiet -c slice/foo
  echo "code" > "$REPO/thing.sh"
  git -C "$REPO" add thing.sh
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add code"
  rc=0; ( cd "$REPO" && "$HELPER" verify-commit --bead foo --base main ) >/dev/null || rc=$?
  equals "$rc" 0
}

@test "verify-commit never invokes the tracker" {
  git -C "$REPO" switch --quiet -c slice/foo
  echo "@test x {}" > "$REPO/thing.bats"
  git -C "$REPO" add thing.bats
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add test"

  ( cd "$REPO" && "$HELPER" verify-commit --bead foo --base main ) >/dev/null
  is_empty "$(cat "$BD_LOG")"
}

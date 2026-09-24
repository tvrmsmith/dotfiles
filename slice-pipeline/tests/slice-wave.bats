load helpers/assert
load helpers/stubs

# slice-wave is the only test seam the Archon slice pipeline has: the workflow
# YAML shells out to it directly, with no seam of its own, so every
# non-trivial rule lives here instead of behind a workflow run.
HELPER="${BATS_TEST_DIRNAME}/../bin/slice-wave"

setup() {
  command -v jq >/dev/null || skip "no jq"

  # Scratch repos must not inherit the developer's git config. Signing is the
  # one that bites: with commit.gpgsign=true and an SSH key, every `git commit`
  # below blocks on the signing agent. An agent that prompts, or one the test
  # harness cannot reach, never answers, so the suite hangs forever instead of
  # failing. Passing -c user.email and -c user.name per commit is not enough,
  # because signing is inherited separately.
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_SYSTEM=/dev/null

  STUB_BIN="$(mktemp -d)"
  export STUB_BIN
  export FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures/axi"
  # Absent unless a test writes it, so no run ever reads the machine's real log.
  export TVRMSMITH_WAIVERS="$STUB_BIN/waivers.jsonl"
  install_stubs

  OLD_PATH="$PATH"
  export PATH="$STUB_BIN:$PATH"

  REPO="$(mktemp -d)"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test \
    commit --quiet --allow-empty -m base
}

assert_detached() {
  rc=0; git -C "$REPO" symbolic-ref -q HEAD >/dev/null || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected a detached HEAD, got $(git -C "$REPO" symbolic-ref HEAD)" >&2; exit 1; }
}

teardown() {
  export PATH="$OLD_PATH"
  rm -rf "$STUB_BIN" "$REPO"
}

@test "an unknown subcommand prints the usage line to stderr and exits 2" {
  rc=0; out="$("$HELPER" resurrect --bead foo 2>"$STUB_BIN/err")" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "usage: slice-wave <branch-name|claim|release|verify-commit|validate>"
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

@test "claim exits 2 without touching the tracker when a flag has no value" {
  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --beads-dir "$STUB_BIN" --bead 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "--bead needs a value"
  is_empty "$(cat "$BD_LOG")"
}

@test "claim exits 2 without touching the tracker on an unknown flag" {
  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" --force yes 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "unknown flag --force"
  is_empty "$(cat "$BD_LOG")"
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
@test "claim exits 1 without touching the tracker when gh cannot see a forge remote" {
  export GH_EXIT_CODE=1
  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "no forge remote you can open pull requests on"
  contains "$(cat "$STUB_BIN/err")" "gh: stub configured to fail"
  is_empty "$(cat "$BD_LOG")"
  equals "$(git -C "$REPO" symbolic-ref --short HEAD)" "main"
}

# shellcheck disable=SC2030
@test "claim exits 1 without touching the tracker when gh reports read-only access" {
  export GH_VIEWER_PERMISSION=READ
  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "no forge remote you can open pull requests on"
  contains "$(cat "$STUB_BIN/err")" "READ"
  is_empty "$(cat "$BD_LOG")"
}

# shellcheck disable=SC2030
@test "claim exits 1 without touching the tracker when no-mistakes is not initialized" {
  export NO_MISTAKES_AXI_EXIT=1
  export NO_MISTAKES_AXI_FIXTURE="$FIXTURES_DIR/not-initialized.toon"
  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "no-mistakes init"
  contains "$(cat "$STUB_BIN/err")" "repo not initialized (run 'no-mistakes init' first)"
  is_empty "$(cat "$BD_LOG")"
  equals "$(git -C "$REPO" symbolic-ref --short HEAD)" "main"
}

@test "claim proceeds to the tracker when branch sync reports run_pipeline" {
  export NO_MISTAKES_STATUS_FIXTURE="$FIXTURES_DIR/status-run-pipeline.toon"
  ( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" ) >/dev/null
  contains "$(cat "$CALL_LOG" | cut -f2)" "axi status"
  lacks "$(cat "$CALL_LOG" | cut -f2)" "axi sync"
  contains "$(cat "$BD_LOG")" "update foo --claim"
}

@test "claim runs the reported sync then claims once a re-read finds no branch_sync" {
  export NO_MISTAKES_STATUS_FIXTURE="$FIXTURES_DIR/status-sync.toon"
  export NO_MISTAKES_SYNC_NEXT_STATUS_FIXTURE="$FIXTURES_DIR/sync-then-clean.toon"
  ( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" ) >/dev/null
  sequence="$(awk -F'\t' '$2 == "axi status" || $2 == "axi sync" || $1 == "bd" { print $2 }' "$CALL_LOG")"
  equals "$sequence" "$(printf 'axi status\naxi sync\naxi status\nupdate foo --claim')"
}

@test "claim refuses and detaches when branch sync reports a code it does not reconcile" {
  export NO_MISTAKES_STATUS_FIXTURE="$FIXTURES_DIR/status-continue-active-run.toon"
  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "continue_active_run"
  contains "$(cat "$STUB_BIN/err")" "no-mistakes axi status"
  is_empty "$(cat "$BD_LOG")"
  assert_detached
}

@test "claim refuses a sync code whose reported command is not a no-mistakes sync" {
  export NO_MISTAKES_STATUS_FIXTURE="$FIXTURES_DIR/status-sync-bad-command.toon"
  # origin/x resolves to the pre-sentinel commit, so if the reported
  # `git reset --hard origin/x` actually ran, HEAD would move there and the
  # sentinel file would disappear. Proves the command claim refuses never
  # actually runs, rather than just asserting on stderr text.
  base_sha="$(git -C "$REPO" rev-parse HEAD)"
  git -C "$REPO" update-ref refs/remotes/origin/x "$base_sha"
  echo sentinel > "$REPO/sentinel"
  git -C "$REPO" add sentinel
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m sentinel

  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "git reset --hard origin/x"
  is_empty "$(cat "$BD_LOG")"
  equals "$(cat "$REPO/sentinel")" "sentinel"
}

@test "claim refuses a reported sync command with anything chained after it, unrun" {
  sed 's/^    command: .*/    command: no-mistakes axi sync; git reset --hard x/' \
    "$FIXTURES_DIR/status-sync.toon" > "$STUB_BIN/status-chained.toon"
  export NO_MISTAKES_STATUS_FIXTURE="$STUB_BIN/status-chained.toon"
  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "refusing to run it"
  lacks "$(cut -f2 "$CALL_LOG")" "axi sync"
  is_empty "$(cat "$BD_LOG")"
  assert_detached
}

@test "claim runs a reported sync with flags as that exact argv" {
  sed 's/^    command: .*/    command: no-mistakes axi sync --recover --keep-local/' \
    "$FIXTURES_DIR/status-sync.toon" > "$STUB_BIN/status-recover.toon"
  export NO_MISTAKES_STATUS_FIXTURE="$STUB_BIN/status-recover.toon"
  export NO_MISTAKES_SYNC_NEXT_STATUS_FIXTURE="$FIXTURES_DIR/sync-then-clean.toon"
  ( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" ) >/dev/null
  contains "$(cat "$CALL_LOG")" "$(printf 'no-mistakes\taxi sync --recover --keep-local\n')"
  contains "$(cat "$BD_LOG")" "update foo --claim"
}

@test "claim refuses and detaches when the reported sync fails" {
  export NO_MISTAKES_STATUS_FIXTURE="$FIXTURES_DIR/status-sync.toon"
  export NO_MISTAKES_SYNC_EXIT=1
  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "'no-mistakes axi sync' failed while reconciling slice/foo"
  contains "$(cat "$STUB_BIN/err")" "error: stub sync configured to fail"
  is_empty "$(cat "$BD_LOG")"
  assert_detached
}

@test "claim refuses and detaches when no-mistakes axi status exits non-zero" {
  export NO_MISTAKES_STATUS_EXIT=1
  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "cannot read no-mistakes axi status for slice/foo"
  is_empty "$(cat "$BD_LOG")"
  assert_detached
}

@test "claim refuses and detaches when no-mistakes axi status reports an error with exit 0" {
  printf 'error: gate state unreadable\n' > "$STUB_BIN/status-error.toon"
  export NO_MISTAKES_STATUS_FIXTURE="$STUB_BIN/status-error.toon"
  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "error: gate state unreadable"
  is_empty "$(cat "$BD_LOG")"
  assert_detached
}

@test "claim gives up after 3 sync rounds when branch sync still reports sync" {
  export NO_MISTAKES_STATUS_FIXTURE="$FIXTURES_DIR/status-sync.toon"
  # No NO_MISTAKES_SYNC_NEXT_STATUS_FIXTURE: the stub keeps returning the same
  # sync-reporting fixture after every `axi sync` call.
  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" 2>/dev/null )" || rc=$?
  equals "$rc" 1
  is_empty "$out"
  is_empty "$(cat "$BD_LOG")"
  sync_calls="$(awk -F'\t' '$2 == "axi sync"' "$CALL_LOG" | wc -l | tr -d ' ')"
  equals "$sync_calls" "3"
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
  ( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" ) >/dev/null 2>"$STUB_BIN/err" || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected non-zero exit, got 0" >&2; exit 1; }
  is_empty "$(cat "$BD_LOG")"
  contains "$(cat "$STUB_BIN/err")" "tracked"
}

# shellcheck disable=SC2030,SC2031
@test "claim detaches the worktree when the tracker refuses, so a retry can take the branch" {
  export BD_EXIT_CODE=1
  ( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" ) >/dev/null 2>&1 || true
  unset BD_EXIT_CODE

  rc=0; git -C "$REPO" symbolic-ref --quiet HEAD >/dev/null || rc=$?
  [ "$rc" -ne 0 ] || { echo "expected a detached HEAD, got $(git -C "$REPO" symbolic-ref HEAD)" >&2; exit 1; }
  retry="$STUB_BIN/retry"
  git -C "$REPO" worktree add --quiet "$retry" main
  ( cd "$retry" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" ) >/dev/null
  equals "$(git -C "$retry" symbolic-ref --short HEAD)" "slice/foo"
}

@test "claim does not claim the bead when it cannot build its output" {
  printf '#!/bin/sh\nexit 1\n' > "$STUB_BIN/jq"
  chmod +x "$STUB_BIN/jq"

  rc=0
  out="$( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" 2>/dev/null )" || rc=$?
  rm "$STUB_BIN/jq"
  [ "$rc" -ne 0 ] || { echo "expected non-zero exit, got 0" >&2; exit 1; }
  is_empty "$out"
  is_empty "$(cat "$BD_LOG")"
  equals "$(git -C "$REPO" symbolic-ref --short HEAD)" "main"
}

@test "release unclaims the bead through the tracker with the beads directory supplied" {
  out="$( cd "$REPO" && "$HELPER" release --bead foo --beads-dir "/tmp/beads-foo" )"
  equals "$out" '{"released":true}'
  contains "$(cat "$BD_LOG")" "$(printf '%s\t%s' "/tmp/beads-foo" 'unclaim foo')"
}

@test "release frees the slice branch so a retry in another worktree can check it out" {
  ( cd "$REPO" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" ) >/dev/null
  ( cd "$REPO" && "$HELPER" release --bead foo --beads-dir "$STUB_BIN" ) >/dev/null

  retry="$STUB_BIN/retry"
  git -C "$REPO" worktree add --quiet "$retry" main
  ( cd "$retry" && "$HELPER" claim --bead foo --beads-dir "$STUB_BIN" ) >/dev/null
  equals "$(git -C "$retry" symbolic-ref --short HEAD)" "slice/foo"
}

@test "release still unclaims the bead when it cannot detach the worktree" {
  plain="$STUB_BIN/not-a-repo"
  mkdir -p "$plain"
  rc=0
  out="$( cd "$plain" && "$HELPER" release --bead foo --beads-dir "$STUB_BIN" 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 0
  equals "$out" '{"released":true}'
  contains "$(cat "$BD_LOG")" "unclaim foo"
  contains "$(cat "$STUB_BIN/err")" "cannot detach"
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
  rc=0; out="$( cd "$REPO" && "$HELPER" release --bead foo --beads-dir "$STUB_BIN" 2>"$STUB_BIN/err" )" || rc=$?
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

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )"
  equals "$(printf '%s' "$out" | jq -c .)" \
    "$(jq -nc --arg sha "$expected_sha" \
      '{verified:true,committed:true,tests_touched:true,branch:"slice/foo",sha:$sha,reason:"",waivers:[],waivers_error:""}')"
}

@test "verify-commit measures the branch against origin/HEAD before main" {
  # origin/HEAD is set to the branch tip, so whichever ref wins decides the
  # verdict: against main there is a commit, against origin/HEAD there is none.
  git -C "$REPO" switch --quiet -c slice/foo
  echo "@test x {}" > "$REPO/thing.bats"
  git -C "$REPO" add thing.bats
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add test"
  git -C "$REPO" update-ref refs/remotes/origin/HEAD "$(git -C "$REPO" rev-parse slice/foo)"

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )"
  equals "$(printf '%s' "$out" | jq -r '.committed')" "false"
  equals "$(printf '%s' "$out" | jq -r '.reason')" "no commit on slice/foo beyond origin/HEAD"
}

@test "verify-commit reports an unresolvable base and exits 0 when no candidate ref exists" {
  git -C "$REPO" branch -m trunk
  git -C "$REPO" branch slice/foo

  rc=0; out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )" || rc=$?
  equals "$rc" 0
  equals "$(printf '%s' "$out" | jq -c .)" \
    '{"verified":false,"committed":false,"tests_touched":false,"branch":"slice/foo","sha":"","reason":"cannot resolve a base ref","waivers":[],"waivers_error":""}'
}

@test "verify-commit reports a failed file listing instead of a missing test file" {
  git -C "$REPO" switch --quiet -c slice/foo
  echo "@test x {}" > "$REPO/thing.bats"
  git -C "$REPO" add thing.bats
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add test"
  real_git="$(command -v git)"
  cat > "$STUB_BIN/git" <<EOF
#!/bin/sh
[ "\$1" = diff ] && { echo "diff exploded" >&2; exit 128; }
exec "$real_git" "\$@"
EOF
  chmod +x "$STUB_BIN/git"

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )"
  rm "$STUB_BIN/git"
  equals "$(printf '%s' "$out" | jq -r '.verified')" "false"
  equals "$(printf '%s' "$out" | jq -r '.reason')" "cannot list the files changed on slice/foo: diff exploded"
}

@test "verify-commit exits 2 on a flag with no value" {
  rc=0; out="$( cd "$REPO" && "$HELPER" verify-commit --bead 2>"$STUB_BIN/err" )" || rc=$?
  equals "$rc" 2
  is_empty "$out"
  contains "$(cat "$STUB_BIN/err")" "--bead needs a value"
}

@test "verify-commit reports not committed when the branch has nothing beyond its base" {
  git -C "$REPO" switch --quiet -c slice/foo

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )"
  equals "$(printf '%s' "$out" | jq -c .)" \
    '{"verified":false,"committed":false,"tests_touched":false,"branch":"slice/foo","sha":"","reason":"no commit on slice/foo beyond main","waivers":[],"waivers_error":""}'
}

@test "verify-commit does not credit a branch this worktree does not have checked out" {
  # Another run's worktree holds slice/foo with a landed test, and this run's
  # claim never got onto it.
  git -C "$REPO" switch --quiet -c slice/foo
  echo "@test x {}" > "$REPO/thing.bats"
  git -C "$REPO" add thing.bats
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add test"
  git -C "$REPO" switch --quiet main

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )"
  equals "$(printf '%s' "$out" | jq -c .)" \
    '{"verified":false,"committed":false,"tests_touched":false,"branch":"slice/foo","sha":"","reason":"this worktree is not on slice/foo, so this run never claimed it","waivers":[],"waivers_error":""}'
}

@test "verify-commit ignores a test file that landed on the base after the branch point" {
  git -C "$REPO" switch --quiet -c slice/foo
  echo "code" > "$REPO/thing.sh"
  git -C "$REPO" add thing.sh
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add code"
  git -C "$REPO" switch --quiet main
  echo "@test x {}" > "$REPO/sibling.bats"
  git -C "$REPO" add sibling.bats
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "sibling test"
  git -C "$REPO" switch --quiet slice/foo

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )"
  equals "$(printf '%s' "$out" | jq -r '.tests_touched')" "false"
  equals "$(printf '%s' "$out" | jq -r '.reason')" "no test file in the commits on slice/foo"
}

@test "verify-commit reports not committed when the derived branch does not exist" {
  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )"
  equals "$(printf '%s' "$out" | jq -c .)" \
    '{"verified":false,"committed":false,"tests_touched":false,"branch":"slice/foo","sha":"","reason":"no branch slice/foo","waivers":[],"waivers_error":""}'
}

@test "verify-commit counts test files in C#, pytest and JUnit layouts" {
  for path in src/Foo.Tests/Bar.cs pkg/test_bar.py src/main/FooTest.java src/BarTests.cs; do
    git -C "$REPO" switch --quiet -C slice/foo main
    mkdir -p "$REPO/$(dirname "$path")"
    echo "x" > "$REPO/$path"
    git -C "$REPO" add -A
    git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add $path"

    out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )"
    equals "$path: $(printf '%s' "$out" | jq -r '.verified')" "$path: true"
    git -C "$REPO" rm -rq "$path"
    git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "drop $path"
  done
}

@test "verify-commit counts a plain file under a tests directory as a test file" {
  # Every other verified case here is decided by the basename arm, so this is
  # the only one that reaches the path-component arm.
  git -C "$REPO" switch --quiet -c slice/foo
  mkdir -p "$REPO/docs/tests"
  echo "notes" > "$REPO/docs/tests/notes.txt"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add notes"

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )"
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

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )"
  equals "$(printf '%s' "$out" | jq -r '.tests_touched')" "false"
  equals "$(printf '%s' "$out" | jq -r '.verified')" "false"
}

@test "verify-commit reports committed but not verified when no test file changed" {
  git -C "$REPO" switch --quiet -c slice/foo
  echo "code" > "$REPO/thing.sh"
  git -C "$REPO" add thing.sh
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add code"
  expected_sha="$(git -C "$REPO" rev-parse slice/foo)"

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )"
  equals "$(printf '%s' "$out" | jq -c .)" \
    "$(jq -nc --arg sha "$expected_sha" \
      '{verified:false,committed:true,tests_touched:false,branch:"slice/foo",sha:$sha,reason:"no test file in the commits on slice/foo",waivers:[],waivers_error:""}')"
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

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )"
  equals "$(printf '%s' "$out" | jq -r '.tests_touched')" "true"
  equals "$(printf '%s' "$out" | jq -r '.verified')" "true"
}

# Commits a test file on slice/foo and prints the commit's tree, the key a
# lint waiver's spend record carries.
commit_slice() {
  git -C "$REPO" switch --quiet -c slice/foo
  echo "@test x {}" > "$REPO/thing.bats"
  git -C "$REPO" add thing.bats
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add test"
  git -C "$REPO" rev-parse 'slice/foo^{tree}'
}

# Appends a waiver record and its spend against tree $2 to the log.
spend_waiver() {
  jq -nc --arg id "$1" '{kind:"waiver",id:$id,language:"go",path:"a.go",rule:"R1",reason:"false positive",recorded:"t"}' >> "$TVRMSMITH_WAIVERS"
  jq -nc --arg id "$1" --arg tree "$2" '{kind:"spend",id:$id,tree:$tree,spent:"t"}' >> "$TVRMSMITH_WAIVERS"
}

@test "verify-commit lists the waivers spent on the slice's commits and no others" {
  tree="$(commit_slice)"
  spend_waiver mine "$tree"
  spend_waiver elsewhere 0000000000000000000000000000000000000000

  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )"
  equals "$(printf '%s' "$out" | jq -c '.waivers')" \
    '[{"id":"mine","language":"go","path":"a.go","rule":"R1","reason":"false positive"}]'
  equals "$(printf '%s' "$out" | jq -r '.verified')" "true"
}

@test "verify-commit reports no waivers when the log does not exist" {
  commit_slice >/dev/null
  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo )"
  equals "$(printf '%s' "$out" | jq -c '.waivers')" "[]"
  is_empty "$(printf '%s' "$out" | jq -r '.waivers_error')"
}

# An empty list alone would claim no waiver went unreviewed, which nobody checked.
@test "verify-commit reports waivers as unknown when the log cannot be parsed" {
  commit_slice >/dev/null
  echo "not json" > "$TVRMSMITH_WAIVERS"
  out="$( cd "$REPO" && "$HELPER" verify-commit --bead foo 2>/dev/null )"
  contains "$(printf '%s' "$out" | jq -r '.waivers_error')" "cannot read the waiver log"
  equals "$(printf '%s' "$out" | jq -r '.verified')" "true"
}

# The workflow node reads the verdict from verified, and a non-zero exit would
# fail the node and throw the artifacts away, so every false verdict exits 0.
@test "verify-commit exits 0 when the derived branch does not exist" {
  rc=0; ( cd "$REPO" && "$HELPER" verify-commit --bead foo ) >/dev/null || rc=$?
  equals "$rc" 0
}

@test "verify-commit exits 0 when the commits touch no test file" {
  git -C "$REPO" switch --quiet -c slice/foo
  echo "code" > "$REPO/thing.sh"
  git -C "$REPO" add thing.sh
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add code"
  rc=0; ( cd "$REPO" && "$HELPER" verify-commit --bead foo ) >/dev/null || rc=$?
  equals "$rc" 0
}

@test "verify-commit never invokes the tracker" {
  git -C "$REPO" switch --quiet -c slice/foo
  echo "@test x {}" > "$REPO/thing.bats"
  git -C "$REPO" add thing.bats
  git -C "$REPO" -c user.email=t@example.com -c user.name=Test commit --quiet -m "add test"

  ( cd "$REPO" && "$HELPER" verify-commit --bead foo ) >/dev/null
  is_empty "$(cat "$BD_LOG")"
}

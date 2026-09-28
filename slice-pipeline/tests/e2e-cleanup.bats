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

# release_archon_registration acts on Archon's own state, not the stub
# fixtures above, so these tests build a throwaway ARCHON_HOME under
# $STUB_BIN instead of reusing the gh/git fixtures.

# Seeds a throwaway Archon home under $STUB_BIN: the archon.db schema, a
# scratch clone's codebase row plus three rows that must survive (an
# unrelated codebase, a sibling path sharing the scratch dir's name as a
# prefix, and an Archon-managed clone), the isolation rows that depend on the
# scratch and managed codebases, and the workspaces symlinks and real
# directory release_archon_registration must leave alone. Given $1, it
# snapshots the codebases into that file before adding the scratch row, as
# e2e.bats does before its run.
seed_archon_fixture() {
  ARCHON_HOME="$STUB_BIN/archon-home"
  export ARCHON_HOME
  mkdir -p "$ARCHON_HOME"
  sqlite3 "$ARCHON_HOME/archon.db" <<'SQL'
CREATE TABLE remote_agent_codebases (id TEXT PRIMARY KEY, name TEXT NOT NULL, default_cwd TEXT NOT NULL, default_branch TEXT);
CREATE TABLE remote_agent_isolation_environments (id TEXT PRIMARY KEY, codebase_id TEXT NOT NULL REFERENCES remote_agent_codebases(id) ON DELETE CASCADE);
SQL

  SCR="$(mktemp -d "$STUB_BIN/scratch.XXXXXX")"
  mkdir -p "$SCR/repo"
  PHYS="$(cd "$SCR" && pwd -P)"

  sqlite3 "$ARCHON_HOME/archon.db" <<SQL
INSERT INTO remote_agent_codebases VALUES ('other', 'owner/other', '$STUB_BIN/elsewhere/repo', 'main');
INSERT INTO remote_agent_codebases VALUES ('sibling', 'owner/sib', '${PHYS}-sibling/repo', 'main');
INSERT INTO remote_agent_codebases VALUES ('cloned', 'owner/cloned', '$ARCHON_HOME/workspaces/owner/cloned/source', 'trunk');
INSERT INTO remote_agent_isolation_environments VALUES ('env2', 'cloned');
SQL
  [ -z "${1:-}" ] || snapshot_archon_registrations "$1"
  sqlite3 "$ARCHON_HOME/archon.db" <<SQL
INSERT INTO remote_agent_codebases VALUES ('scratch', 'owner/repo', '$PHYS/repo', 'main');
INSERT INTO remote_agent_isolation_environments VALUES ('env1', 'scratch');
SQL

  mkdir -p "$ARCHON_HOME/workspaces/owner/repo" \
    "$ARCHON_HOME/workspaces/owner/other" \
    "$ARCHON_HOME/workspaces/owner/sib" \
    "$ARCHON_HOME/workspaces/owner/cloned/source"
  ln -s "$PHYS/repo" "$ARCHON_HOME/workspaces/owner/repo/source"
  ln -s "$STUB_BIN/elsewhere/repo" "$ARCHON_HOME/workspaces/owner/other/source"
  ln -s "${PHYS}-sibling/repo" "$ARCHON_HOME/workspaces/owner/sib/source"
  echo x > "$ARCHON_HOME/workspaces/owner/cloned/source/file"
}

@test "releasing a scratch clone deletes its codebase row and the rows that depend on it" {
  command -v sqlite3 >/dev/null || skip "no sqlite3"
  seed_archon_fixture

  release_archon_registration "$SCR"

  equals "$(sqlite3 "$ARCHON_HOME/archon.db" 'select id from remote_agent_codebases order by id')" "$(printf 'cloned\nother\nsibling')"
  equals "$(sqlite3 "$ARCHON_HOME/archon.db" 'select id from remote_agent_isolation_environments')" env2
}

@test "releasing a scratch clone removes the source symlink into it and no other" {
  command -v sqlite3 >/dev/null || skip "no sqlite3"
  seed_archon_fixture

  release_archon_registration "$SCR"

  if [ -L "$ARCHON_HOME/workspaces/owner/repo/source" ] || [ -e "$ARCHON_HOME/workspaces/owner/repo/source" ]; then
    echo "expected workspaces/owner/repo/source to be gone" >&2
    exit 1
  fi

  [ -L "$ARCHON_HOME/workspaces/owner/other/source" ] ||
    { echo "expected workspaces/owner/other/source to remain a symlink" >&2; exit 1; }
  equals "$(readlink "$ARCHON_HOME/workspaces/owner/other/source")" "$STUB_BIN/elsewhere/repo"
  equals "$(readlink "$ARCHON_HOME/workspaces/owner/sib/source")" "${PHYS}-sibling/repo"

  [ -d "$ARCHON_HOME/workspaces/owner/cloned/source" ] ||
    { echo "expected workspaces/owner/cloned/source to remain a directory" >&2; exit 1; }
  contains "$(cat "$ARCHON_HOME/workspaces/owner/cloned/source/file")" x
}

@test "a scratch named through a symlink still matches the physical path Archon recorded" {
  command -v sqlite3 >/dev/null || skip "no sqlite3"
  seed_archon_fixture
  ln -s "$SCR" "$STUB_BIN/alias"

  release_archon_registration "$STUB_BIN/alias"

  equals "$(sqlite3 "$ARCHON_HOME/archon.db" 'select id from remote_agent_codebases order by id')" "$(printf 'cloned\nother\nsibling')"
  if [ -L "$ARCHON_HOME/workspaces/owner/repo/source" ] || [ -e "$ARCHON_HOME/workspaces/owner/repo/source" ]; then
    echo "expected workspaces/owner/repo/source to be gone" >&2
    exit 1
  fi
}

@test "with no Archon database, release touches nothing and fails nothing" {
  ARCHON_HOME="$STUB_BIN/empty-archon-home"
  export ARCHON_HOME
  mkdir -p "$ARCHON_HOME/workspaces/owner/other"
  ln -s "$STUB_BIN/elsewhere/repo" "$ARCHON_HOME/workspaces/owner/other/source"
  SCR="$(mktemp -d "$STUB_BIN/scratch.XXXXXX")"

  run release_archon_registration "$SCR"

  equals "$status" 0
  equals "$(readlink "$ARCHON_HOME/workspaces/owner/other/source")" "$STUB_BIN/elsewhere/repo"
  [ ! -e "$ARCHON_HOME/archon.db" ] ||
    { echo "expected no archon.db to be created" >&2; exit 1; }
}

@test "when sqlite3 fails, release still removes the source symlink and fails nothing" {
  command -v sqlite3 >/dev/null || skip "no sqlite3"
  ARCHON_HOME="$STUB_BIN/broken-archon-home"
  export ARCHON_HOME
  mkdir -p "$ARCHON_HOME/workspaces/owner/repo"
  sqlite3 "$ARCHON_HOME/archon.db" 'CREATE TABLE unrelated (id TEXT);'
  SCR="$(mktemp -d "$STUB_BIN/scratch.XXXXXX")"
  PHYS="$(cd "$SCR" && pwd -P)"
  ln -s "$PHYS/repo" "$ARCHON_HOME/workspaces/owner/repo/source"

  release_archon_registration "$SCR" 2>"$STUB_BIN/err"

  contains "$(cat "$STUB_BIN/err")" "# cannot release"
  if [ -L "$ARCHON_HOME/workspaces/owner/repo/source" ] || [ -e "$ARCHON_HOME/workspaces/owner/repo/source" ]; then
    echo "expected workspaces/owner/repo/source to be gone" >&2
    exit 1
  fi
}

@test "releasing an already deleted scratch by its recorded path still drops its row and link" {
  command -v sqlite3 >/dev/null || skip "no sqlite3"
  seed_archon_fixture
  rm -rf "$SCR"

  release_archon_registration "$PHYS"

  equals "$(sqlite3 "$ARCHON_HOME/archon.db" 'select id from remote_agent_codebases order by id')" "$(printf 'cloned\nother\nsibling')"
  if [ -L "$ARCHON_HOME/workspaces/owner/repo/source" ] || [ -e "$ARCHON_HOME/workspaces/owner/repo/source" ]; then
    echo "expected workspaces/owner/repo/source to be gone" >&2
    exit 1
  fi
  equals "$(readlink "$ARCHON_HOME/workspaces/owner/sib/source")" "${PHYS}-sibling/repo"
}

@test "a codebase row that predates the run and was rewritten into scratch is restored, not deleted" {
  command -v sqlite3 >/dev/null || skip "no sqlite3"
  seed_archon_fixture "$STUB_BIN/snapshot.sql"
  sqlite3 "$ARCHON_HOME/archon.db" "UPDATE remote_agent_codebases SET default_cwd = '$PHYS/repo', default_branch = 'e2e/demo' WHERE id = 'cloned'"

  release_archon_registration "$SCR" "$STUB_BIN/snapshot.sql"

  equals "$(sqlite3 "$ARCHON_HOME/archon.db" 'select id from remote_agent_codebases order by id')" "$(printf 'cloned\nother\nsibling')"
  equals "$(sqlite3 -separator ' ' "$ARCHON_HOME/archon.db" "select default_cwd, default_branch from remote_agent_codebases where id = 'cloned'")" \
    "$ARCHON_HOME/workspaces/owner/cloned/source trunk"
  equals "$(sqlite3 "$ARCHON_HOME/archon.db" 'select id from remote_agent_isolation_environments')" env2
}

@test "an unreadable snapshot skips the DB step, so a rewritten pre-existing row is not deleted" {
  command -v sqlite3 >/dev/null || skip "no sqlite3"
  bats_require_minimum_version 1.5.0
  seed_archon_fixture "$STUB_BIN/snapshot.sql"
  sqlite3 "$ARCHON_HOME/archon.db" "UPDATE remote_agent_codebases SET default_cwd = '$PHYS/repo', default_branch = 'e2e/demo' WHERE id = 'cloned'"

  run --separate-stderr release_archon_registration "$SCR" "$STUB_BIN/missing.sql"

  equals "$status" 0
  contains "$stderr" "# cannot read snapshot"
  equals "$(sqlite3 "$ARCHON_HOME/archon.db" 'select id from remote_agent_codebases order by id')" "$(printf 'cloned\nother\nscratch\nsibling')"
  equals "$(sqlite3 -separator ' ' "$ARCHON_HOME/archon.db" "select default_cwd, default_branch from remote_agent_codebases where id = 'cloned'")" \
    "$PHYS/repo e2e/demo"
  if [ -L "$ARCHON_HOME/workspaces/owner/repo/source" ] || [ -e "$ARCHON_HOME/workspaces/owner/repo/source" ]; then
    echo "expected workspaces/owner/repo/source to be gone" >&2
    exit 1
  fi
}

@test "a snapshot taken with no Archon database is empty and fails nothing" {
  ARCHON_HOME="$STUB_BIN/empty-archon-home"
  export ARCHON_HOME

  snapshot_archon_registrations "$STUB_BIN/snapshot.sql"

  [ -f "$STUB_BIN/snapshot.sql" ] && [ ! -s "$STUB_BIN/snapshot.sql" ] ||
    { echo "expected an empty snapshot file" >&2; exit 1; }
  [ ! -e "$ARCHON_HOME/archon.db" ] ||
    { echo "expected no archon.db to be created" >&2; exit 1; }
}

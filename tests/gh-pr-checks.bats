load helpers/assert

# gh-pr-checks rebuilds `gh pr checks` from commit statuses and Actions jobs,
# because GitHub withdrew the Checks permission from fine-grained tokens. A stub
# gh makes the whole thing a function of canned API responses: no network, no
# token, no keychain.
HELPER="${BATS_TEST_DIRNAME}/../dot-local/bin/gh-pr-checks"

setup() {
  command -v jq >/dev/null || skip "no jq"
  BIN="$(mktemp -d)"
  export REAL_GH="$BIN/gh" CHECK_RUNS_CODE=403
  export STATUSES='{"statuses":[]}' RUNS='{"workflow_runs":[]}' JOBS='{"jobs":[]}'

  # Emulates just enough gh: routes on the api path, and applies --jq itself
  # since the helper leans on gh to filter.
  cat > "$BIN/gh" <<'EOF'
#!/bin/bash
sub="$1"
jqf=""; path=""; silent=""
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --jq|-q) jqf="$2"; shift 2 ;;
    -i|--silent) silent=1; shift ;;
    --json|-R|--repo) shift 2 ;;
    -*) shift ;;
    *) [ -n "$path" ] || path="$1"; shift ;;
  esac
done

if [ "$sub" = pr ]; then
  echo '{"number":1,"headRefOid":"deadbeef"}'
  exit 0
fi

case "$path" in
  *check-runs*) echo "HTTP/2.0 $CHECK_RUNS_CODE Whatever"; exit 0 ;;
  */status)     body="$STATUSES" ;;
  *actions/runs\?*) body="$RUNS" ;;
  *actions/runs/*/jobs*) body="$JOBS" ;;
  repos/*)      echo "o/r"; exit 0 ;;
  *)            body='{}' ;;
esac
if [ -n "$jqf" ]; then printf '%s' "$body" | jq -r "$jqf"; else printf '%s\n' "$body"; fi
EOF
  chmod +x "$BIN/gh"
}

teardown() { rm -rf "$BIN"; }

one_status() {
  export STATUSES='{"statuses":[{"context":"snyk","state":"'"$1"'","target_url":"u1",
    "description":"d","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:05Z"}]}'
}

one_job() {
  export RUNS='{"workflow_runs":[{"id":7}]}'
  export JOBS='{"jobs":[{"name":"build","status":"'"$1"'","conclusion":'"$2"',
    "started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:01:04Z",
    "html_url":"u2","workflow_name":"CI"}]}'
}

run_helper() { "$HELPER" "$@" -R o/r 2>/dev/null; }

@test "a status and an Actions job land in one table" {
  one_status success
  one_job completed '"success"'
  out="$(run_helper 1)"
  contains "$out" "snyk	pass	5s	u1	d"
  contains "$out" "build	pass	1m4s	u2"
}

@test "a failing job exits 1, the code gh uses" {
  one_status success
  one_job completed '"failure"'
  rc=0; run_helper 1 >/dev/null || rc=$?
  equals "$rc" 1
}

@test "a job still running exits 8, not 0" {
  # The distinction is the whole point of the exit code: a caller that treats
  # pending as success merges on a green that has not happened yet.
  one_job in_progress 'null'
  rc=0; run_helper 1 >/dev/null || rc=$?
  equals "$rc" 8
}

@test "everything passing exits 0" {
  one_status success
  one_job completed '"success"'
  rc=0; run_helper 1 >/dev/null || rc=$?
  equals "$rc" 0
}

@test "a skipped job is not a failure" {
  one_job completed '"skipped"'
  out="$(run_helper 1)"
  contains "$out" "build	skipping"
  rc=0; run_helper 1 >/dev/null || rc=$?
  equals "$rc" 0
}

# The rebuild cannot see a check posted as an App check run. Where the Checks
# API does answer, which is every public repo, gh's own output is the better
# answer and the helper must get out of the way.
@test "a readable Checks API hands straight over to gh" {
  CHECK_RUNS_CODE=200
  one_status failure
  out="$("$HELPER" 1 -R o/r 2>/dev/null)"
  # The stub's `pr` branch answers, so this is gh's output, not a rebuilt table.
  contains "$out" '"headRefOid":"deadbeef"'
  lacks "$out" "snyk"
}

@test "--json emits only the fields asked for" {
  one_status success
  out="$(run_helper 1 --json name,bucket)"
  equals "$(printf '%s' "$out" | jq -c '.[0]')" '{"name":"snyk","bucket":"pass"}'
}

@test "--jq runs against the same rows" {
  one_status pending
  equals "$(run_helper 1 --json name,bucket --jq '.[] | .bucket')" pending
}

@test "a pending commit status counts as pending, not failed" {
  one_status pending
  rc=0; run_helper 1 >/dev/null || rc=$?
  equals "$rc" 8
}

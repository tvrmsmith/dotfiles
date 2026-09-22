#!/usr/bin/env bash
#
# Targeted local validation for the slice pipeline: the two bats suites that
# drive `dot-local/bin/slice-wave` and the declared fixtures for the
# implement-slice workflow. Deliberately not the repository suite, which remote
# CI owns.
#
# Writes into $NO_MISTAKES_COVERAGE_DIR, which lives outside the worktree:
#   report.xml            bats JUnit report
#   archon-fixtures.xml   JUnit report for the workflow fixture run
#   lcov.info             line coverage for dot-local/bin/slice-wave
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

OUT="${NO_MISTAKES_COVERAGE_DIR:?set NO_MISTAKES_COVERAGE_DIR to a directory outside the worktree}"
case "$OUT" in
	"$ROOT" | "$ROOT"/*)
		echo "local-test: NO_MISTAKES_COVERAGE_DIR ($OUT) is inside the worktree" >&2
		exit 1
		;;
esac
mkdir -p "$OUT" || exit 1

SUITES="tests/slice-wave.bats tests/implement-slice-wiring.bats"
WORKFLOW_DIR=".archon/workflows/pipeline/implement-slice"
COV_SOURCE="dot-local/bin/slice-wave"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- bats suites, with the coverage probe armed -----------------------------
export SLICE_COV_BASENAME="${COV_SOURCE##*/}"
export SLICE_COV_OUT="$WORK/hits"
export BASH_ENV="$ROOT/tests/helpers/coverage-prelude.sh"
: > "$SLICE_COV_OUT"

# shellcheck disable=SC2086 # SUITES is a deliberate word-split list.
bats --print-output-on-failure --report-formatter junit --output "$OUT" $SUITES
bats_rc=$?

unset BASH_ENV SLICE_COV_BASENAME SLICE_COV_OUT

# --- workflow fixtures ------------------------------------------------------
# `archon workflow test` is the only seam for the YAML half of the change: it
# replays fixtures/*.stubs.yaml offline, never contacting a provider.
fixture_log="$WORK/fixtures.log"
if command -v archon >/dev/null 2>&1; then
	archon workflow test "$WORKFLOW_DIR" >"$fixture_log" 2>&1
	fixture_rc=$?
else
	fixture_rc=127
	echo "archon is not on PATH, so the implement-slice fixtures did not run" >"$fixture_log"
fi
cat "$fixture_log"

{
	printf '<?xml version="1.0" encoding="UTF-8"?>\n'
	printf '<testsuites>\n'
	printf '  <testsuite name="archon-fixtures" tests="1" failures="%s">\n' \
		"$([ "$fixture_rc" -eq 0 ] && echo 0 || echo 1)"
	printf '    <testcase classname="%s" name="declared fixtures replay">\n' "$WORKFLOW_DIR"
	if [ "$fixture_rc" -ne 0 ]; then
		printf '      <failure message="archon workflow test exited %s"><![CDATA[\n' "$fixture_rc"
		# CDATA cannot nest, so split any literal terminator in the log.
		sed 's/]]>/]]]]><![CDATA[>/g' "$fixture_log"
		printf ']]></failure>\n'
	fi
	printf '    </testcase>\n  </testsuite>\n</testsuites>\n'
} >"$OUT/archon-fixtures.xml"

# --- LCOV -------------------------------------------------------------------
# Instrumentable lines are the non-blank, non-comment ones minus bare block
# terminators, which bash never reports as executing.
awk -v sf="$COV_SOURCE" '
	FNR == NR { if ($0 ~ /^[0-9]+$/) hits[$0]++; next }
	{
		maxline = FNR
		line = $0
		sub(/^[ \t]+/, "", line)
		sub(/[ \t]+$/, "", line)
		if (line == "" || line ~ /^#/) next
		if (line ~ /^(fi|done|esac|else|then|do|\{|\}|\)|;;)$/) next
		da[FNR] = 1
	}
	END {
		print "TN:"
		print "SF:" sf
		lf = 0; lh = 0
		for (i = 1; i <= maxline; i++) {
			if (!(i in da) && !(i in hits)) continue
			c = (i in hits) ? hits[i] : 0
			print "DA:" i "," c
			lf++
			if (c > 0) lh++
		}
		print "LF:" lf
		print "LH:" lh
		print "end_of_record"
	}
' "$WORK/hits" "$COV_SOURCE" >"$OUT/lcov.info"

covered="$(awk -F: '/^LH:/ { print $2 }' "$OUT/lcov.info")"
if [ "${covered:-0}" -eq 0 ]; then
	echo "local-test: coverage probe recorded no lines of $COV_SOURCE" >&2
	exit 1
fi

printf 'local-test: bats rc=%s, fixtures rc=%s, %s lines covered in %s\n' \
	"$bats_rc" "$fixture_rc" "$covered" "$COV_SOURCE"

[ "$bats_rc" -eq 0 ] && [ "$fixture_rc" -eq 0 ]

#!/usr/bin/env bash
#
# Targeted local validation for the slice pipeline: the two bats suites that
# drive `bin/slice-wave` and the declared fixtures for the implement-slice
# workflow. Every path below is relative to slice-pipeline/, so this runner
# moves with the subproject rather than with the repo hosting it.
#
# Writes into $NO_MISTAKES_COVERAGE_DIR, which lives outside the worktree:
#   report.xml            bats JUnit report
#   archon-fixtures.xml   JUnit report for the workflow fixture run
#   lcov.info             line coverage for bin/slice-wave
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

OUT="${NO_MISTAKES_COVERAGE_DIR:?set NO_MISTAKES_COVERAGE_DIR to a directory outside the worktree}"
# Guarded against the whole worktree, not against $ROOT. $ROOT is the
# subproject, so a coverage directory elsewhere in the host repo would clear a
# $ROOT-only check while still writing artifacts into tracked space.
GUARD="$(git rev-parse --show-toplevel 2>/dev/null || echo "$ROOT")"
case "$OUT" in
	"$GUARD" | "$GUARD"/*)
		echo "local-test: NO_MISTAKES_COVERAGE_DIR ($OUT) is inside the worktree" >&2
		exit 1
		;;
esac
mkdir -p "$OUT" || exit 1

SUITES="tests/slice-wave.bats tests/implement-slice-wiring.bats"
WORKFLOW_DIR="workflows/implement-slice"
COV_SOURCE="bin/slice-wave"

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
#
# It cannot simply be pointed at a path. Fixture discovery scans three fixed
# scopes (the project's .archon/workflows, the global one, and the bundled one)
# and a path argument only filters what those already found, so a tree outside
# all three is never discovered. Verified on Archon 0.10.1.
#
# Hence a throwaway ARCHON_HOME whose global scope holds this workflow. Two
# details are load-bearing:
#
#   copy, not symlink  fixture discovery does not follow symlinks, even though
#                      workflow discovery does, so a linked tree loads the
#                      workflow and then reports no fixtures for it
#   the pack level     a workflow directory placed directly under workflows/
#                      makes archon read its fixtures/ dir as a second packaged
#                      workflow and fail to load it
#
# Copying also means this checks the tree it ships with rather than whatever
# version install.sh last linked onto the machine.
fixture_log="$WORK/fixtures.log"
if command -v archon >/dev/null 2>&1; then
	fixture_home="$WORK/archon-home"
	mkdir -p "$fixture_home/workflows/slice-pipeline"
	cp -R "$ROOT/$WORKFLOW_DIR" "$fixture_home/workflows/slice-pipeline/"
	ARCHON_HOME="$fixture_home" archon workflow test implement-slice >"$fixture_log" 2>&1
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
#
# Function records are emitted as well as line records. A reader that asks
# which functions a suite entered, rather than which lines it ran, sees nothing
# in a report carrying only DA. A `name() {` line declares the function; its
# call count is the hit count of the first instrumentable line of its body,
# which bash reports once per entry.
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
		if (line ~ /^[A-Za-z_][A-Za-z0-9_]*\(\)[ \t]*\{$/) {
			name = line
			sub(/\(\).*/, "", name)
			fnname[++nfn] = name
			fnline[nfn] = FNR
		}
	}
	END {
		print "TN:"
		print "SF:" sf
		for (f = 1; f <= nfn; f++) print "FN:" fnline[f] "," fnname[f]
		fnh = 0
		for (f = 1; f <= nfn; f++) {
			calls = 0
			for (i = fnline[f] + 1; i <= maxline; i++) {
				if (!(i in da)) continue
				calls = (i in hits) ? hits[i] : 0
				break
			}
			print "FNDA:" calls "," fnname[f]
			if (calls > 0) fnh++
		}
		print "FNF:" nfn
		print "FNH:" fnh
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

# Every function the file declares has to have been entered. A function no test
# calls is the gap this report exists to expose, so it fails the run here rather
# than passing a green report with a hole in it.
uncalled="$(awk -F'[:,]' '/^FNDA:/ && $2 == 0 { printf " %s", $3 }' "$OUT/lcov.info")"
if [ -n "$uncalled" ]; then
	echo "local-test: no test entered these functions of $COV_SOURCE:$uncalled" >&2
	exit 1
fi

fn_hit="$(awk -F: '/^FNH:/ { print $2 }' "$OUT/lcov.info")"
printf 'local-test: bats rc=%s, fixtures rc=%s, %s lines and %s functions covered in %s\n' \
	"$bats_rc" "$fixture_rc" "$covered" "$fn_hit" "$COV_SOURCE"

[ "$bats_rc" -eq 0 ] && [ "$fixture_rc" -eq 0 ]

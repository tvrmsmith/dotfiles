# shellcheck shell=bash
# Line-coverage probe for a bash script under test, sourced through BASH_ENV by
# every non-interactive bash the suite starts. `tests/local-test.sh` sets it up.
#
# macOS ships bash 3.2, which has no BASH_XTRACEFD, so `set -x` would put the
# trace on stderr that several tests assert on. A DEBUG trap writing $LINENO to
# its own file leaves stdout and stderr alone, and bash restores $? around the
# trap, so the traced script's exit statuses are unchanged.
#
# The match is on basename, not full path: BASH_SOURCE[0] holds the path as the
# caller wrote it, which is a PATH entry in one suite and a `../`-relative
# absolute path in the other.
if [ -n "${SLICE_COV_BASENAME:-}" ]; then
	trap '[ "${BASH_SOURCE[0]##*/}" = "${SLICE_COV_BASENAME:-}" ] && printf "%s\n" "$LINENO" >> "${SLICE_COV_OUT:-/dev/null}" || :' DEBUG
	# functrace, so the trap reaches functions, subshells and command
	# substitutions rather than only the top level.
	set -T
fi

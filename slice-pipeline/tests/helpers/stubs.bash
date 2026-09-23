# Shared fakes for slice-wave's external tools: bd (the issue tracker), gh
# (the forge), and no-mistakes (the validation gate). Every stub appends one
# line per call, tool name then argv tab-separated, to $CALL_LOG, so a test
# can assert the order calls happened in across tools. bd also keeps writing
# its pre-existing $BD_LOG in the BEADS_DIR-then-argv shape, since tests
# written before gh and no-mistakes existed assert on that shape directly.
#
# Call install_stubs from setup() once $STUB_BIN and $FIXTURES_DIR are
# exported; it writes the three scripts into $STUB_BIN and initializes the
# logs. Every knob a test can turn (exit codes, which fixture a stub prints)
# is a plain env var the script reads at call time rather than one baked in
# at generation time, so a test exports it, runs the helper under test, and
# lets teardown's fresh $STUB_BIN clear it for the next test.
install_stubs() {
	export BD_LOG="$STUB_BIN/bd.log"
	export CALL_LOG="$STUB_BIN/call.log"
	: > "$BD_LOG"
	: > "$CALL_LOG"
	unset BD_EXIT_CODE BD_SHOW_JSON GH_EXIT_CODE GH_VIEWER_PERMISSION \
		GH_PR_LIST_JSON GH_PR_COMMENT_EXIT NO_MISTAKES_RUN_SEQUENCE \
		NO_MISTAKES_AXI_EXIT NO_MISTAKES_AXI_FIXTURE \
		NO_MISTAKES_STATUS_EXIT NO_MISTAKES_STATUS_FIXTURE \
		NO_MISTAKES_SYNC_EXIT NO_MISTAKES_SYNC_NEXT_STATUS_FIXTURE

	cat > "$STUB_BIN/bd" <<'EOF'
#!/bin/bash
printf '%s\t%s\n' "${BEADS_DIR:-}" "$*" >> "$BD_LOG"
printf 'bd\t%s\n' "$*" >> "$CALL_LOG"
if [ "${BD_EXIT_CODE:-0}" -ne 0 ]; then
	echo "bd: stub configured to fail" >&2
	exit "$BD_EXIT_CODE"
fi
if [ "${1:-}" = show ]; then
	default='[{"id":"demo-1","title":"Demo slice","description":"Adds the demo.","acceptance_criteria":"The demo prints hello.","notes":""}]'
	printf '%s\n' "${BD_SHOW_JSON:-$default}"
fi
EOF
	chmod +x "$STUB_BIN/bd"

	# Default: a forge remote claim can open pull requests on, with no open
	# pull request for the branch. `pr comment` saves the body it reads on
	# stdin to $STUB_BIN/pr-comment-body, so a test can read what was posted.
	cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
printf 'gh\t%s\n' "$*" >> "$CALL_LOG"
if [ "${GH_EXIT_CODE:-0}" -ne 0 ]; then
	echo "gh: stub configured to fail" >&2
	exit "${GH_EXIT_CODE:-0}"
fi
case "${1:-} ${2:-}" in
	"pr list") printf '%s\n' "${GH_PR_LIST_JSON:-[]}" ;;
	"pr comment")
		cat > "$STUB_BIN/pr-comment-body"
		exit "${GH_PR_COMMENT_EXIT:-0}"
		;;
	*) printf '{"nameWithOwner":"owner/repo","viewerPermission":"%s"}\n' "${GH_VIEWER_PERMISSION:-WRITE}" ;;
esac
EOF
	chmod +x "$STUB_BIN/gh"

	# Default: an initialized gate (`axi` home view) reporting no branch_sync
	# on `axi status`, and an `axi run` that ends checks-passed. `axi sync`, when told to, swaps the fixture the next
	# `axi status` call prints, so a test can script a sync resolving what it
	# was called to resolve.
	cat > "$STUB_BIN/no-mistakes" <<'EOF'
#!/bin/bash
printf 'no-mistakes\t%s\n' "$*" >> "$CALL_LOG"
case "$1" in
	axi)
		case "${2:-}" in
			status)
				fixture="${NO_MISTAKES_STATUS_FIXTURE:-$FIXTURES_DIR/sync-then-clean.toon}"
				[ -f "$STUB_BIN/status-fixture-override" ] && fixture="$(cat "$STUB_BIN/status-fixture-override")"
				cat "$fixture"
				exit "${NO_MISTAKES_STATUS_EXIT:-0}"
				;;
			sync)
				if [ -n "${NO_MISTAKES_SYNC_NEXT_STATUS_FIXTURE:-}" ]; then
					printf '%s' "$NO_MISTAKES_SYNC_NEXT_STATUS_FIXTURE" > "$STUB_BIN/status-fixture-override"
				fi
				exit "${NO_MISTAKES_SYNC_EXIT:-0}"
				;;
			run)
				# NO_MISTAKES_RUN_SEQUENCE lists one fixture:exit pair per call,
				# space-separated, so a test can script a run that reattaches.
				# Calls past the end repeat the last pair.
				calls="$(cat "$STUB_BIN/run-calls" 2>/dev/null || echo 0)"
				echo $((calls + 1)) > "$STUB_BIN/run-calls"
				set -- ${NO_MISTAKES_RUN_SEQUENCE:-$FIXTURES_DIR/checks-passed.toon:0}
				[ "$calls" -lt $# ] || calls=$(($# - 1))
				shift "$calls"
				cat "${1%:*}"
				exit "${1##*:}"
				;;
			"")
				fixture="${NO_MISTAKES_AXI_FIXTURE:-$FIXTURES_DIR/home-clean.toon}"
				cat "$fixture"
				exit "${NO_MISTAKES_AXI_EXIT:-0}"
				;;
			*)
				echo "no-mistakes: stub does not know axi ${2:-}" >&2
				exit 1
				;;
		esac
		;;
	*)
		echo "no-mistakes: stub does not know $1" >&2
		exit 1
		;;
esac
EOF
	chmod +x "$STUB_BIN/no-mistakes"
}

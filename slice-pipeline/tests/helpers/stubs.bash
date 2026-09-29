# Shared fakes for slice-wave's external tools: bd (the issue tracker), gh
# (the forge), no-mistakes (the validation gate), orca (the editor hosting
# the review tab) and tuicr (the review tool). Every stub appends one
# line per call, tool name then argv tab-separated, to $CALL_LOG, so a test
# can assert the order calls happened in across tools. bd also keeps writing
# its pre-existing $BD_LOG in the BEADS_DIR-then-argv shape, since tests
# written before gh and no-mistakes existed assert on that shape directly.
#
# Call install_stubs from setup() once $STUB_BIN and $FIXTURES_DIR are
# exported; it writes the scripts into $STUB_BIN and initializes the
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
		GH_PR_LIST_JSON GH_PR_COMMENT_EXIT GH_PR_MERGE_EXIT GH_PR_VIEW_STATES \
		GH_PR_DISABLE_AUTO_EXIT GH_API_GRAPHQL_EXIT \
		NO_MISTAKES_RUN_SEQUENCE \
		NO_MISTAKES_AXI_EXIT NO_MISTAKES_AXI_FIXTURE \
		NO_MISTAKES_STATUS_EXIT NO_MISTAKES_STATUS_FIXTURE \
		NO_MISTAKES_SYNC_EXIT NO_MISTAKES_SYNC_NEXT_STATUS_FIXTURE \
		GH_PR_HEAD_OID \
		ORCA_TERMINAL_LIST_JSON ORCA_TERMINAL_LIST_EXIT \
		ORCA_REPO_LIST_JSON ORCA_REPO_LIST_EXIT ORCA_REPO_ADD_EXIT \
		ORCA_TERMINAL_CREATE_EXIT ORCA_TERMINAL_CREATE_SURFACE \
		TUICR_LIST_SEQUENCE TUICR_COMMENTS_JSON TUICR_COMMENTS_EXIT

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
	# `pr merge` succeeds, and every pull request read reports it merged.
	cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
printf 'gh\t%s\n' "$*" >> "$CALL_LOG"
# The fields gh 2.101.0's `pr view --json` accepts.
GH_PR_VIEW_FIELDS="additions assignees author autoMergeRequest baseRefName baseRefOid body
	changedFiles closed closedAt closingIssuesReferences comments commits createdAt deletions
	files fullDatabaseId headRefName headRefOid headRepository headRepositoryOwner id
	isCrossRepository isDraft labels latestReviews maintainerCanModify mergeCommit
	mergeStateStatus mergeable mergedAt mergedBy milestone number potentialMergeCommit
	projectCards projectItems reactionGroups reviewDecision reviewRequests reviews state
	statusCheckRollup title updatedAt url"
if [ "${GH_EXIT_CODE:-0}" -ne 0 ]; then
	echo "gh: stub configured to fail" >&2
	exit "${GH_EXIT_CODE:-0}"
fi
# Sets pr to the next pull request read, from either `pr view` or a GraphQL
# query. GH_PR_VIEW_STATES lists one state per read, space-separated, so a
# test can script a merge that lands after a few polls. Reads past the end
# repeat the last state, and FAIL makes that read exit 1. A state suffixed
# :queued reads as sitting in the merge queue. Every read reports
# GH_PR_HEAD_OID as the head commit.
pr_read() {
	local calls
	calls="$(cat "$STUB_BIN/pr-view-calls" 2>/dev/null || echo 0)"
	echo $((calls + 1)) > "$STUB_BIN/pr-view-calls"
	set -- ${GH_PR_VIEW_STATES:-MERGED}
	[ "$calls" -lt $# ] || calls=$(($# - 1))
	shift "$calls"
	[ "$1" != FAIL ] || { echo "gh: stub pr view configured to fail" >&2; exit 1; }
	local queued=false
	[ "${1#*:}" != queued ] || queued=true
	pr="$(printf '{"state":"%s","url":"https://github.com/owner/repo/pull/42","isInMergeQueue":%s,"id":"PR_stub42","headRefOid":"%s"}' \
		"${1%%:*}" "$queued" "${GH_PR_HEAD_OID:-0123456789abcdef0123456789abcdef01234567}")"
}
case "${1:-} ${2:-}" in
	"pr list") printf '%s\n' "${GH_PR_LIST_JSON:-[]}" ;;
	"pr comment")
		cat > "$STUB_BIN/pr-comment-body"
		exit "${GH_PR_COMMENT_EXIT:-0}"
		;;
	"pr merge")
		case " $* " in
			*" --disable-auto "*)
				[ "${GH_PR_DISABLE_AUTO_EXIT:-0}" -eq 0 ] || echo "GraphQL: auto-merge could not be disabled" >&2
				exit "${GH_PR_DISABLE_AUTO_EXIT:-0}"
				;;
		esac
		[ "${GH_PR_MERGE_EXIT:-0}" -eq 0 ] || echo "GraphQL: Pull request is not mergeable" >&2
		exit "${GH_PR_MERGE_EXIT:-0}"
		;;
	"api graphql")
		query=""
		jq_filter=.
		prev=""
		for arg in "$@"; do
			[ "$prev" != -f ] || [ "${arg%%=*}" != query ] || query="${arg#query=}"
			[ "$prev" != --jq ] || jq_filter="$arg"
			prev="$arg"
		done
		case "$query" in
			*dequeuePullRequest*)
				[ "${GH_API_GRAPHQL_EXIT:-0}" -eq 0 ] || echo "GraphQL: Could not dequeue pull request" >&2
				exit "${GH_API_GRAPHQL_EXIT:-0}"
				;;
		esac
		# A pull request read: answer with the fields the query selects.
		fields="$(sed -n 's/.*pullRequest(number: [^)]*) { \([^}]*\) }.*/\1/p' <<<"$query")"
		fields="${fields// /,}"
		pr_read
		printf '%s\n' "$pr" |
			jq -c --arg fields "$fields" '. as $pr | {data: {repository: {pullRequest: ($fields | split(",") | map({(.): $pr[.]}) | add)}}}' |
			jq -c "$jq_filter"
		;;
	"pr view")
		# Like real gh, it prints only the keys the call names after --json,
		# and refuses a key gh 2.101.0 does not offer, such as isInMergeQueue.
		fields=""
		prev=""
		for arg in "$@"; do
			[ "$prev" != --json ] || fields="$arg"
			prev="$arg"
		done
		known=" $(echo $GH_PR_VIEW_FIELDS) "
		for field in ${fields//,/ }; do
			case "$known" in
				*" $field "*) ;;
				*) echo "Unknown JSON field: \"$field\"" >&2; exit 1 ;;
			esac
		done
		pr_read
		printf '%s\n' "$pr" |
			jq -c --arg fields "$fields" '. as $pr | $fields | split(",") | map({(.): $pr[.]}) | add'
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
				[ "${NO_MISTAKES_SYNC_EXIT:-0}" -eq 0 ] || echo "error: stub sync configured to fail" >&2
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

	# Default: an Orca with no tabs and no registered repositories, whose
	# `repo add` and `terminal create` succeed, the create landing as a
	# visible tab. A command's *_JSON knob replaces what it prints, and its
	# *_EXIT knob makes it fail, printing Orca's error envelope instead.
	cat > "$STUB_BIN/orca" <<'EOF'
#!/bin/bash
printf 'orca\t%s\n' "$*" >> "$CALL_LOG"
# Prints Orca's error envelope for command $1 and exits $2.
fail() {
	printf '{"ok":false,"error":{"code":"stub_failure","message":"orca: stub %s configured to fail"}}\n' "$1"
	exit "$2"
}
case "${1:-} ${2:-}" in
	"terminal list")
		[ "${ORCA_TERMINAL_LIST_EXIT:-0}" -eq 0 ] || fail "terminal list" "$ORCA_TERMINAL_LIST_EXIT"
		default='{"ok":true,"result":{"terminals":[],"visualLayouts":[]}}'
		printf '%s\n' "${ORCA_TERMINAL_LIST_JSON:-$default}"
		;;
	"repo list")
		[ "${ORCA_REPO_LIST_EXIT:-0}" -eq 0 ] || fail "repo list" "$ORCA_REPO_LIST_EXIT"
		default='{"ok":true,"result":{"repos":[]}}'
		printf '%s\n' "${ORCA_REPO_LIST_JSON:-$default}"
		;;
	"repo add")
		[ "${ORCA_REPO_ADD_EXIT:-0}" -eq 0 ] || fail "repo add" "$ORCA_REPO_ADD_EXIT"
		printf '{"ok":true,"result":{"repo":{"id":"repo-stub"}}}\n'
		;;
	"terminal create")
		[ "${ORCA_TERMINAL_CREATE_EXIT:-0}" -eq 0 ] || fail "terminal create" "$ORCA_TERMINAL_CREATE_EXIT"
		printf '{"ok":true,"result":{"terminal":{"handle":"term_stub","surface":"%s"}}}\n' \
			"${ORCA_TERMINAL_CREATE_SURFACE:-visible}"
		;;
	*)
		echo "orca: stub does not know $*" >&2
		exit 1
		;;
esac
EOF
	chmod +x "$STUB_BIN/orca"

	# Default: no persisted review session and no comments. TUICR_LIST_SEQUENCE
	# lists what each `review list` call prints, one line per call. Lines, not
	# words, because a session path may hold spaces. Calls past the end repeat
	# the last line, and FAIL makes that call exit 1.
	cat > "$STUB_BIN/tuicr" <<'EOF'
#!/bin/bash
printf 'tuicr\t%s\n' "$*" >> "$CALL_LOG"
case "${1:-} ${2:-}" in
	"review list")
		calls="$(cat "$STUB_BIN/tuicr-list-calls" 2>/dev/null || echo 0)"
		echo $((calls + 1)) > "$STUB_BIN/tuicr-list-calls"
		sequence="${TUICR_LIST_SEQUENCE:-[]}"
		lines="$(printf '%s\n' "$sequence" | wc -l | tr -d ' ')"
		[ "$calls" -lt "$lines" ] || calls=$((lines - 1))
		read_line="$(printf '%s\n' "$sequence" | sed -n "$((calls + 1))p")"
		[ "$read_line" != FAIL ] || { echo "tuicr: stub review list configured to fail" >&2; exit 1; }
		printf '%s\n' "$read_line"
		;;
	"review comments")
		[ "${TUICR_COMMENTS_EXIT:-0}" -eq 0 ] || { echo "tuicr: stub review comments configured to fail" >&2; exit "$TUICR_COMMENTS_EXIT"; }
		printf '%s\n' "${TUICR_COMMENTS_JSON:-[]}"
		;;
	*)
		echo "tuicr: stub does not know $*" >&2
		exit 1
		;;
esac
EOF
	chmod +x "$STUB_BIN/tuicr"
}

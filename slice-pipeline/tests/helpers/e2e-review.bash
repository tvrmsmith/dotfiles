# The engineer's half of the live e2e's review step. The run parks in review
# until someone sends from the review tab it opens, so the suite plays that
# engineer: it finds the tab in Orca, waits for tuicr to persist the pull
# request's review session, and sends an empty `:send`, the approval that is
# the run's only way through to merge.
#
# Needs Orca running, and a tuicr built from Trevor's fork branch `groupdiff`:
# upstream tuicr drops a released session on quit and reports no head_sha in
# `review list`, and review-round needs both.

# Waits for the review tab of bead $1's pull request on GitHub repository $2,
# then approves it with an empty send. Sets REVIEW_TAB_TITLE, REVIEW_HANDLE
# (the tab's pane) and REVIEW_PR (the <n> in the tab's `review $1 #<n>`
# title) for the caller to export. Both waits share one deadline,
# SLICE_E2E_REVIEW_TIMEOUT_SECONDS from the call (default 16200, 4.5 hours,
# since build and validate both run before review opens a tab). Gives up early
# once process $3, the workflow run, exits, since a run that failed before
# review never opens a tab. Returns 1 with the reason on stderr when it
# cannot send.
send_empty_review() {
	local bead="$1" repo="$2" run_pid="$3" deadline tab slug
	local tool
	for tool in orca tuicr; do
		command -v "$tool" >/dev/null || {
			echo "# no $tool, so nobody can send from the review tab" >&2
			return 1
		}
	done
	deadline=$((SECONDS + ${SLICE_E2E_REVIEW_TIMEOUT_SECONDS:-16200}))

	# A split nests groups, so tabs are searched at any depth, and so is the
	# pane inside the tab.
	until tab="$(orca terminal list --json --include-visual-layouts 2>/dev/null | jq -ce --arg bead "$bead" '
		[.result.visualLayouts[]?.root | .. | objects | .tabs? | arrays | .[]
		 | select((.title // "") | test("^review \($bead) #[0-9]+$"))
		 | {title, handle: ([.panes | .. | objects | select(.type == "terminal") | .handle] | first)}]
		| first // empty')"; do
		review_wait_ok "$run_pid" "$deadline" "no review tab for $bead" || return 1
	done
	REVIEW_TAB_TITLE="$(jq -r .title <<<"$tab")"
	REVIEW_HANDLE="$(jq -r '.handle // empty' <<<"$tab")"
	REVIEW_PR="${REVIEW_TAB_TITLE##*#}"
	[ -n "$REVIEW_HANDLE" ] || {
		echo "# the review tab '$REVIEW_TAB_TITLE' holds no terminal pane to send from: $tab" >&2
		return 1
	}

	# A send before tuicr has persisted the session has nothing to release.
	slug="gh:$repo/pr/$REVIEW_PR"
	until tuicr review list --repo "$repo" 2>/dev/null | jq -e --arg slug "$slug" 'any(.[]; .slug == $slug)' >/dev/null 2>&1; do
		review_wait_ok "$run_pid" "$deadline" "no tuicr session $slug" || return 1
	done

	orca terminal send --terminal "$REVIEW_HANDLE" --text ':send' --enter >/dev/null || {
		echo "# orca could not send :send to $REVIEW_HANDLE in '$REVIEW_TAB_TITLE'" >&2
		return 1
	}
}

# Sleeps one poll interval, or returns 1 with $3 on stderr once run $1 has
# exited or deadline $2 has passed.
review_wait_ok() {
	local run_pid="$1" deadline="$2" waiting_for="$3"
	kill -0 "$run_pid" 2>/dev/null || {
		echo "# $waiting_for, and the run has already exited" >&2
		return 1
	}
	[ "$SECONDS" -lt "$deadline" ] || {
		echo "# $waiting_for after ${SLICE_E2E_REVIEW_TIMEOUT_SECONDS:-16200}s" >&2
		return 1
	}
	sleep 10
}

# Stops process $1 and every process under it. Killing the run alone would
# leave its review-round polling for hours behind it. The tree is listed
# before anything is killed, so no orphan escapes to launchd first.
stop_run() {
	local pids="$1" frontier="$1"
	while frontier="$(pgrep -P "$frontier" | paste -sd, -)" && [ -n "$frontier" ]; do
		pids="$pids,$frontier"
	done
	# shellcheck disable=SC2086 # a deliberate word-split list of pids.
	kill ${pids//,/ } 2>/dev/null
}

# Closes the review tab whose pane is $1, if send_empty_review found one.
# Never fails the caller; a problem goes to stderr for a human to finish.
close_review_tab() {
	[ -n "${1:-}" ] || return 0
	orca terminal close --terminal "$1" --tab >/dev/null 2>&1 ||
		echo "# cannot close the review tab holding $1; close it in Orca by hand" >&2
}

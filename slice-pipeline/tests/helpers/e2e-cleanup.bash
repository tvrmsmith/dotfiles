# Closes every open pull request on GitHub repository $1 whose head is the
# slice branch $2, then deletes $2 from the origin of the clone at $3. Looked
# up by branch rather than from validate's pr_number, since a red run can push
# the branch and open a pull request without validate naming it.
#
# Acts only on a branch under slice/, since `gh pr list --head ""` applies no
# filter at all and would list every open pull request on the repository. Each
# listed pull request's headRefName is checked too, for the same reason.
# Problems go to stderr for a human to finish by hand; nothing here fails.
close_slice_branch() {
	local repo="$1" branch="$2" clone="$3" prs pr
	case "$branch" in
		slice/?*) ;;
		*)
			echo "# no slice branch ('$branch'); closed no pull request and deleted no branch on $repo" >&2
			return 0
			;;
	esac
	if prs="$(gh pr list -R "$repo" --head "$branch" --state open --json number,headRefName 2>&1)" &&
		prs="$(printf '%s' "$prs" | jq -r --arg b "$branch" '.[] | select(.headRefName == $b) | .number' 2>&1)"; then
		for pr in $prs; do
			gh pr close "$pr" -R "$repo" >/dev/null 2>&1 ||
				echo "# gh pr close $pr failed on $repo; close it by hand" >&2
		done
	else
		echo "# cannot list open pull requests for $branch on $repo; close them by hand. gh said: $prs" >&2
	fi
	if git -C "$clone" ls-remote --exit-code origin "refs/heads/$branch" >/dev/null 2>&1; then
		git -C "$clone" push --quiet origin --delete "$branch" >/dev/null 2>&1 ||
			echo "# cannot delete $branch on $repo; delete it by hand" >&2
	fi
}

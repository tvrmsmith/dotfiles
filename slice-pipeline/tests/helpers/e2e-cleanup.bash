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

# registerRepository records a workflow run's scratch clone as its target
# repository's codebase: a remote_agent_codebases row whose default_cwd is
# the clone's physical path, plus a workspaces/<owner>/<repo>/source symlink
# to that path. Archon has no CLI to drop either, and teardown deletes the
# scratch dir, so the next run against another clone of the same repository
# trips a dangling symlink or a codebase row pointing nowhere. This drops
# both, matched against the scratch dir as given and its physical path
# (`cd` resolves the same symlink hops Archon did when it recorded the row),
# so a sibling path sharing the scratch dir's name as a prefix is left alone.
# Never fails the caller; problems go to stderr for a human to finish by hand.
release_archon_registration() {
	local scratch="$1" home db phys
	home="${ARCHON_HOME:-$HOME/.archon}"
	db="$home/archon.db"

	phys="$(cd "$scratch" 2>/dev/null && pwd -P)" || phys=""

	if [ -f "$db" ] && ! command -v sqlite3 >/dev/null 2>&1; then
		echo "# no sqlite3; delete the codebase row for $scratch from $db by hand" >&2
	elif [ -f "$db" ]; then
		local where out
		where="$(_archon_path_match_sql default_cwd "$scratch")"
		if [ -n "$phys" ] && [ "$phys" != "$scratch" ]; then
			where="$where OR $(_archon_path_match_sql default_cwd "$phys")"
		fi
		out="$(sqlite3 "$db" "PRAGMA foreign_keys=ON; DELETE FROM remote_agent_codebases WHERE $where;" 2>&1)" ||
			echo "# cannot release Archon's registration of $scratch in $db; delete it by hand. sqlite3 said: $out" >&2
	fi

	local link target matched
	for link in "$home"/workspaces/*/*/source; do
		[ -L "$link" ] || continue
		target="$(readlink "$link")"
		matched=false
		case "$target" in
			"$scratch" | "$scratch"/*) matched=true ;;
		esac
		if [ "$matched" = false ] && [ -n "$phys" ]; then
			case "$target" in
				"$phys" | "$phys"/*) matched=true ;;
			esac
		fi
		[ "$matched" = true ] || continue
		rm -f "$link" || echo "# cannot remove $link, which points into $scratch; remove it by hand" >&2
	done

	return 0
}

# Builds a `column matches P or starts with P/` SQL predicate for path $2,
# without LIKE, which would treat a literal `_` in the path as a wildcard.
_archon_path_match_sql() {
	local col="$1" path="$2" esc
	esc="${path//\'/\'\'}"
	printf "(%s = '%s' OR substr(%s, 1, length('%s') + 1) = '%s' || '/')" \
		"$col" "$esc" "$col" "$esc" "$esc"
}

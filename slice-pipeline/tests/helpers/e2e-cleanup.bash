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
#
# A codebase row that already existed is not Archon's new registration: when
# it points at an Archon-managed clone, Archon rewrites its default_cwd to the
# scratch clone instead of inserting a row. Given $2, a file written by
# snapshot_archon_registrations before the run, a matching row whose id is in
# it gets its default_cwd and default_branch back instead of being deleted.
# Never fails the caller; problems go to stderr for a human to finish by hand.
release_archon_registration() {
	local scratch="$1" snapshot="${2:-}" home db phys
	home="${ARCHON_HOME:-$HOME/.archon}"
	db="$home/archon.db"

	phys="$(cd "$scratch" 2>/dev/null && pwd -P)" || phys=""

	if [ -f "$db" ] && ! command -v sqlite3 >/dev/null 2>&1; then
		echo "# no sqlite3; delete the codebase row for $scratch from $db by hand" >&2
	elif [ -f "$db" ] && [ -n "$snapshot" ] && [ ! -r "$snapshot" ]; then
		echo "# cannot read snapshot $snapshot; release Archon's registration of $scratch in $db by hand" >&2
	elif [ -f "$db" ]; then
		local where out
		where="$(_archon_path_match_sql default_cwd "$scratch")"
		if [ -n "$phys" ] && [ "$phys" != "$scratch" ]; then
			where="$where OR $(_archon_path_match_sql default_cwd "$phys")"
		fi
		out="$({
			echo "PRAGMA foreign_keys=ON; BEGIN;"
			echo "CREATE TEMP TABLE snap (id TEXT PRIMARY KEY, default_cwd TEXT, default_branch TEXT);"
			[ -z "$snapshot" ] || cat "$snapshot"
			echo "UPDATE remote_agent_codebases SET
				default_cwd = (SELECT default_cwd FROM snap WHERE snap.id = remote_agent_codebases.id),
				default_branch = (SELECT default_branch FROM snap WHERE snap.id = remote_agent_codebases.id)
				WHERE ($where) AND id IN (SELECT id FROM snap);"
			echo "DELETE FROM remote_agent_codebases WHERE ($where) AND id NOT IN (SELECT id FROM snap);"
			echo "COMMIT;"
		} | sqlite3 -bail "$db" 2>&1)" ||
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

# Writes every remote_agent_codebases row's id, default_cwd and default_branch
# to $1 as INSERTs into the snap table release_archon_registration reads.
# Leaves $1 empty when there is no Archon database or no sqlite3; never fails.
snapshot_archon_registrations() {
	local file="$1" db out
	db="${ARCHON_HOME:-$HOME/.archon}/archon.db"
	: >"$file" || return 0
	[ -f "$db" ] && command -v sqlite3 >/dev/null 2>&1 || return 0
	out="$(sqlite3 -readonly -cmd '.mode insert snap' "$db" \
		'SELECT id, default_cwd, default_branch FROM remote_agent_codebases;' 2>&1)" || {
		echo "# cannot snapshot Archon's codebases in $db; teardown will delete, not restore, any it matches. sqlite3 said: $out" >&2
		return 0
	}
	printf '%s\n' "$out" >"$file"
}

# Builds a `column matches P or starts with P/` SQL predicate for path $2,
# without LIKE, which would treat a literal `_` in the path as a wildcard.
_archon_path_match_sql() {
	local col="$1" path="$2" esc
	esc="${path//\'/\'\'}"
	printf "(%s = '%s' OR substr(%s, 1, length('%s') + 1) = '%s' || '/')" \
		"$col" "$esc" "$col" "$esc" "$esc"
}

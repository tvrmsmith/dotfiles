# Returns 0 only when GitHub repository $1 and the clone of it at $2 both carry
# a committed .slice-e2e-sandbox at the root of their default branch, the mark
# of a repository whose history nobody keeps. e2e.bats merges into its target,
# and an unguarded run once merged into this project's own main.
#
# Both sides are checked because they can be different repositories. Pushes go
# to the clone's origin, merges go through gh to $1 (GH_REPO), and
# SLICE_E2E_CLONE_URL lets the two differ. The clone side reads HEAD rather
# than the working tree, so a stray untracked file does not count. Problems go
# to stderr.
require_e2e_sandbox() {
	local repo="$1" clone="$2"

	if ! git -C "$clone" cat-file -e HEAD:.slice-e2e-sandbox 2>/dev/null; then
		echo "# $repo's clone carries no committed .slice-e2e-sandbox; the e2e refuses to push to or merge into an unmarked repository" >&2
		return 1
	fi

	if ! gh api "repos/$repo/contents/.slice-e2e-sandbox" >/dev/null 2>&1; then
		echo "# $repo carries no .slice-e2e-sandbox on its default branch; the e2e refuses to push to or merge into an unmarked repository" >&2
		return 1
	fi
}

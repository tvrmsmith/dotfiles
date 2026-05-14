# Shared helpers for nono and dsbx

# Detect if cwd is a git worktree. Sets _GIT_WORKTREE_SOURCE_REPO if so.
_detect_git_worktree() {
  _GIT_WORKTREE_SOURCE_REPO=""
  local git_common_dir
  git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  local source_repo="$(cd "$git_common_dir/.." && pwd)"
  [[ "$source_repo" != "$(pwd)" ]] || return 1
  _GIT_WORKTREE_SOURCE_REPO="$source_repo"
}

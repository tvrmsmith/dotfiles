# nono (nsjail) agent launchers

# ── Nono (nsjail) ────────────────────────────────────────────────────────────

_OMP_VERTEX="GOOGLE_CLOUD_PROJECT=$ANTHROPIC_VERTEX_PROJECT_ID GOOGLE_CLOUD_LOCATION=$CLOUD_ML_REGION"
alias pi="$_OMP_VERTEX command pi --model $OMP_MODEL"
alias omp="$_OMP_VERTEX command omp --model $OMP_MODEL"

nono-agent() {
  local worktree_args=()
  if _detect_git_worktree; then
    local git_dir abs_common_dir
    git_dir="$(git rev-parse --absolute-git-dir)"
    abs_common_dir="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
    worktree_args=(--read "$_GIT_WORKTREE_SOURCE_REPO" --allow "$git_dir" --allow "$abs_common_dir")
  fi

  GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=$DEV_PERSONAL/dotfiles/dot-ssh/known_hosts.pinned" \
    nono run --allow-cwd --override-deny ~/.config/gcloud "${worktree_args[@]}" "$@"
}

# Claude Code
alias nono-cc='nono-agent --profile claude-code-mise -- claude --dangerously-skip-permissions'
nono-cc-personal() { OP_ACCOUNT=my.1password.com nono-agent --profile claude-code-personal -- claude --dangerously-skip-permissions "$@"; }
alias nono-cc-csharp='nono-agent --profile claude-code-csharp -- claude --dangerously-skip-permissions'
# Oh My Pi
alias nono-omp="$_OMP_VERTEX nono-agent --profile omp-mise -- omp --model $OMP_MODEL"
nono-omp-personal() { env ${=_OMP_VERTEX} OP_ACCOUNT=my.1password.com nono-agent --profile omp-personal -- omp --model $OMP_MODEL "$@"; }
alias nono-omp-csharp="$_OMP_VERTEX nono-agent --profile omp-csharp -- omp --model $OMP_MODEL"

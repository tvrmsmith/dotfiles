# nono (nsjail) agent launchers

# ── Nono (nsjail) ────────────────────────────────────────────────────────────


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

# Maps the work op:// references from the environment into the sandbox. They
# are set by ~/.zshenv.work, so the shared claude-code-mise profile names no
# vault. Each map is skipped when its reference is unset.
_nono_work_credential_maps() {
  reply=()
  [[ -n "$GIT_TOKEN" ]] && reply+=(--env-credential-map "$GIT_TOKEN" GH_TOKEN)
  [[ -n "$JIRA_TOKEN_REF" ]] && reply+=(--env-credential-map "$JIRA_TOKEN_REF" JIRA_API_TOKEN)
}

# Claude Code
# These used to be aliases; drop them so re-sourcing can define the functions.
unalias nono-cc nono-cc-csharp 2>/dev/null
nono-cc() { local reply; _nono_work_credential_maps; nono-agent --profile claude-code-mise "${reply[@]}" -- claude --dangerously-skip-permissions "$@"; }
nono-cc-personal() { OP_ACCOUNT=my.1password.com nono-agent --profile claude-code-personal -- claude --dangerously-skip-permissions "$@"; }
nono-cc-csharp() { local reply; _nono_work_credential_maps; nono-agent --profile claude-code-csharp "${reply[@]}" -- claude --dangerously-skip-permissions "$@"; }

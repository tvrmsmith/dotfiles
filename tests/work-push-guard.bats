load helpers/assert

HOOK="${BATS_TEST_DIRNAME}/../dot-claude/hooks/work-push-guard.sh"

setup() {
  SCRATCH="$(mktemp -d)"
  POLICY="$SCRATCH/managed-settings.json"
  echo '{}' > "$POLICY"
  export WORK_PUSH_GUARD_POLICY_FILES="$SCRATCH/absent.json:$POLICY"

  PERSONAL="$SCRATCH/personal"
  WORK="$SCRATCH/work"
  git init -q "$PERSONAL" && git -C "$PERSONAL" remote add origin git@github-personal:tvrmsmith/dotfiles.git
  git init -q "$WORK" && git -C "$WORK" remote add origin git@github.com:mediwareinc/some-repo.git
}
teardown() { rm -rf "$SCRATCH"; }

# Pipes a Bash payload carrying command $1, run from directory $2.
run_hook() {
  jq -n --arg c "$1" --arg d "$2" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}' | bash "$HOOK"
}

decision_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty'; }
reason_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'; }

@test "without the managed policy file the guard stays out of the way" {
  export WORK_PUSH_GUARD_POLICY_FILES="$SCRATCH/absent.json"
  is_empty "$(run_hook 'git push' "$PERSONAL")"
}

@test "a push to a personal repo is denied and the agent is told to commit and stop" {
  out="$(run_hook 'git push origin main' "$PERSONAL")"
  equals "$(decision_of "$out")" "deny"
  contains "$(reason_of "$out")" "tvrmsmith"
  contains "$(reason_of "$out")" "Commit locally and stop"
}

@test "a push to a WellSky org passes" {
  is_empty "$(run_hook 'git push -u origin HEAD' "$WORK")"
}

@test "the repo is found through git -C and through a leading cd" {
  equals "$(decision_of "$(run_hook "git -C $PERSONAL push" "$WORK")")" "deny"
  equals "$(decision_of "$(run_hook "cd $PERSONAL && git push" "$WORK")")" "deny"
  is_empty "$(run_hook "cd $WORK && git push" "$PERSONAL")"
}

@test "a push inside a compound command is still caught" {
  equals "$(decision_of "$(run_hook 'git add -A && git commit -m x; git push' "$PERSONAL")")" "deny"
}

@test "a URL given in place of a remote is judged by its owner" {
  equals "$(decision_of "$(run_hook 'git push git@github.com:tvrmsmith/x.git main' "$WORK")")" "deny"
  is_empty "$(run_hook 'git push https://github.com/careport/x.git main' "$PERSONAL")"
}

@test "an unresolvable remote asks rather than guessing" {
  equals "$(decision_of "$(run_hook 'git push nosuchremote main' "$WORK")")" "ask"
}

@test "a non-GitHub host asks" {
  git -C "$WORK" remote add ado https://dev.azure.com/org/project/_git/repo
  equals "$(decision_of "$(run_hook 'git push ado main' "$WORK")")" "ask"
}

@test "gh pr create and merge are judged by --repo, a PR URL, or the origin remote" {
  equals "$(decision_of "$(run_hook 'gh pr create -R tvrmsmith/dotfiles --fill' "$WORK")")" "deny"
  is_empty "$(run_hook 'gh pr create --repo mediwareinc/some-repo --fill' "$PERSONAL")"
  equals "$(decision_of "$(run_hook 'gh pr create --fill' "$PERSONAL")")" "deny"
  is_empty "$(run_hook 'gh pr merge 12 --squash' "$WORK")"
  equals "$(decision_of "$(run_hook 'gh pr merge https://github.com/tvrmsmith/dotfiles/pull/3' "$WORK")")" "deny"
}

@test "gh repo create needs an allowed org; a bare name lands on a user account" {
  equals "$(decision_of "$(run_hook 'gh repo create scratch --private' "$WORK")")" "deny"
  equals "$(decision_of "$(run_hook 'gh repo create tvrmsmith/scratch --private' "$WORK")")" "deny"
  is_empty "$(run_hook 'gh repo create mediwareinc/scratch --internal' "$PERSONAL")"
}

@test "commands that only mention a push are left alone" {
  is_empty "$(run_hook 'git status && git log --oneline' "$PERSONAL")"
  is_empty "$(run_hook 'echo git push' "$PERSONAL")"
  is_empty "$(run_hook 'gh pr view 3' "$PERSONAL")"
}

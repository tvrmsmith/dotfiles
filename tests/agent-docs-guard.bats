load helpers/assert

HOOK="${BATS_TEST_DIRNAME}/../dot-claude/hooks/agent-docs-guard.sh"

setup() {
  TMP="$(mktemp -d)"
  # The hook dedupes its nudge per session under TMPDIR, so each test gets its
  # own TMPDIR and its own session id. Sharing either would let the first test
  # to run spend the single nudge every later one asserts on.
  export TMPDIR="$TMP"
  SESSION="$(date +%s)-$RANDOM"
  REPO="$TMP/repo"
  mkdir -p "$REPO"
}
teardown() { rm -rf "$TMP"; }

# Pipes a PreToolUse payload for tool $1 against path $2 at the hook.
hook_out() {
  jq -n --arg t "$1" --arg v "$2" --arg s "$SESSION" \
    '{tool_name: $t, session_id: $s, tool_input: {file_path: $v}}' | bash "$HOOK"
}

# Pipes a Bash payload carrying command $1.
bash_out() {
  jq -n --arg v "$1" --arg s "$SESSION" \
    '{tool_name: "Bash", session_id: $s, tool_input: {command: $v}}' | bash "$HOOK"
}

context_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
decision_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty'; }

@test "an interactive write to AGENTS.md gets the skill nudge, no deny" {
  out="$(hook_out Write "$REPO/AGENTS.md")"
  contains "$(context_of "$out")" "writing-for-agents"
  is_empty "$(decision_of "$out")"
}

@test "NM_GATE denies a write to AGENTS.md" {
  out="$(NM_GATE=1 hook_out Write "$REPO/AGENTS.md")"
  equals "$(decision_of "$out")" "deny"
}

@test "NM_GATE denies CLAUDE.md, CLAUDE.local.md and a nested AGENTS.md" {
  for f in CLAUDE.md CLAUDE.local.md docs/AGENTS.md; do
    out="$(NM_GATE=1 hook_out Edit "$REPO/$f")"
    equals "$(decision_of "$out")" "deny"
  done
}

@test "NM_GATE denies every file-editing tool, not just Write" {
  for t in Edit MultiEdit NotebookEdit; do
    out="$(NM_GATE=1 hook_out "$t" "$REPO/CLAUDE.md")"
    equals "$(decision_of "$out")" "deny"
  done
}

# The nudge is spent after one edit per session; a deny that shared that marker
# would wave through every write after the first.
@test "NM_GATE still denies after the session nudge is spent" {
  spend="$(hook_out Write "$REPO/skills/x/SKILL.md")"
  contains "$(context_of "$spend")" "writing-for-agents"
  out="$(NM_GATE=1 hook_out Write "$REPO/AGENTS.md")"
  equals "$(decision_of "$out")" "deny"
}

@test "NM_GATE denies a shell redirect onto AGENTS.md" {
  out="$(NM_GATE=1 bash_out 'echo hi >> AGENTS.md')"
  equals "$(decision_of "$out")" "deny"
}

@test "NM_GATE denies an in-place sed and a git checkout of CLAUDE.md" {
  out="$(NM_GATE=1 bash_out "sed -i '' s/a/b/ CLAUDE.md")"
  equals "$(decision_of "$out")" "deny"
  out="$(NM_GATE=1 bash_out 'git checkout HEAD -- CLAUDE.md')"
  equals "$(decision_of "$out")" "deny"
}

# Reading is how a gate agent learns the project's rules, so it stays open.
@test "NM_GATE leaves a read of AGENTS.md alone" {
  out="$(NM_GATE=1 bash_out 'cat AGENTS.md')"
  is_empty "$(decision_of "$out")"
  out="$(NM_GATE=1 hook_out Read "$REPO/AGENTS.md")"
  is_empty "$(decision_of "$out")"
}

# The deny is narrower than the nudge: agent-facing craft the gate may still fix.
@test "NM_GATE leaves SKILL.md and an ordinary file alone" {
  out="$(NM_GATE=1 hook_out Write "$REPO/skills/x/SKILL.md")"
  is_empty "$(decision_of "$out")"
  out="$(NM_GATE=1 hook_out Write "$REPO/main.go")"
  is_empty "$(decision_of "$out")"
}

@test "NM_GATE leaves a longer filename merely ending in CLAUDE.md alone" {
  out="$(NM_GATE=1 hook_out Write "$REPO/MY-CLAUDE.md")"
  is_empty "$(decision_of "$out")"
  out="$(NM_GATE=1 bash_out 'echo hi > MY-CLAUDE.md')"
  is_empty "$(decision_of "$out")"
}

@test "the deny names the file class and the reporting route" {
  out="$(NM_GATE=1 hook_out Write "$REPO/AGENTS.md")"
  reason="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')"
  contains "$reason" "agent instruction files"
  contains "$reason" "finding"
}

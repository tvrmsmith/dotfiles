load helpers/assert

HOOK="${BATS_TEST_DIRNAME}/../dot-claude/hooks/adr-guard.sh"

setup() {
  TMP="$(mktemp -d)"
  ADR_DIR="$TMP/docs/adr"
  mkdir -p "$ADR_DIR"
}
teardown() { rm -rf "$TMP"; }

# Pipes a PreToolUse payload for tool $1 against path-or-command $2 at the hook,
# returning its raw stdout.
hook_out() {
  local tool="$1" target="$2" key="file_path"
  [ "$tool" = "Bash" ] && key="command"
  jq -n --arg t "$tool" --arg k "$key" --arg v "$target" \
    '{tool_name: $t, tool_input: {($k): $v}}' | bash "$HOOK"
}

context_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty'; }
decision_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty'; }

@test "an interactive write gets the amend/supersede guidance, no deny" {
  out="$(hook_out Write "$ADR_DIR/0001-x.md")"
  contains "$(context_of "$out")" "Amend it"
  contains "$(context_of "$out")" "Supersede it"
  is_empty "$(decision_of "$out")"
}

@test "the write guidance cites no repo's ADR README" {
  out="$(hook_out Write "$ADR_DIR/0001-x.md")"
  lacks "$(context_of "$out")" "README.md"
}

@test "a read gets the constraint guidance, no deny" {
  out="$(hook_out Read "$ADR_DIR/0001-x.md")"
  contains "$(context_of "$out")" "decision already made"
  is_empty "$(decision_of "$out")"
}

@test "NM_GATE denies a write, citing no repo's ADR README" {
  out="$(NM_GATE=1 hook_out Write "$ADR_DIR/0001-x.md")"
  equals "$(decision_of "$out")" "deny"
  lacks "$out" "README.md"
}

@test "NM_GATE leaves a read alone" {
  out="$(NM_GATE=1 hook_out Read "$ADR_DIR/0001-x.md")"
  is_empty "$(decision_of "$out")"
}

@test "a mutating Bash command against an ADR is a write under NM_GATE" {
  out="$(NM_GATE=1 hook_out Bash "rm docs/adr/0001-x.md")"
  equals "$(decision_of "$out")" "deny"
}

@test "an inspecting Bash command against an ADR stays a read" {
  out="$(NM_GATE=1 hook_out Bash "git log docs/adr/0001-x.md")"
  is_empty "$(decision_of "$out")"
}

@test "a write outside docs/adr is untouched" {
  out="$(hook_out Write "$TMP/not-adr/README.md")"
  is_empty "$out"
}

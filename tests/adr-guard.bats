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

# Pipes a Bash payload for command $1, run as if from $TMP, so a relative
# `docs/adr/...` path in the command resolves against the fixture.
bash_out() {
  jq -n --arg v "$1" --arg cwd "$TMP" \
    '{tool_name: "Bash", cwd: $cwd, tool_input: {command: $v}}' | bash "$HOOK"
}

# Pipes an Edit payload replacing $1 with $2 in an ADR.
edit_out() {
  jq -n --arg f "$ADR_DIR/0007-x.md" --arg o "$1" --arg n "$2" \
    '{tool_name: "Edit", tool_input: {file_path: $f, old_string: $o, new_string: $n}}' \
    | bash "$HOOK"
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

@test "NM_GATE lets a rename within docs/adr through, with renumber guidance" {
  out="$(NM_GATE=1 bash_out "git mv docs/adr/0007-x.md docs/adr/0009-x.md")"
  is_empty "$(decision_of "$out")"
  contains "$(context_of "$out")" "ADR renumber"
}

@test "a bare mv renames too" {
  out="$(NM_GATE=1 bash_out "mv docs/adr/0007-x.md docs/adr/0009-x.md")"
  is_empty "$(decision_of "$out")"
}

@test "NM_GATE denies a rename onto an ADR that already exists" {
  touch "$ADR_DIR/0009-x.md"
  out="$(NM_GATE=1 bash_out "mv docs/adr/0007-x.md docs/adr/0009-x.md")"
  equals "$(decision_of "$out")" "deny"
}

@test "NM_GATE denies a move out of the ADR directory" {
  out="$(NM_GATE=1 bash_out "mv docs/adr/0007-x.md docs/0007-x.md")"
  equals "$(decision_of "$out")" "deny"
}

@test "NM_GATE denies a rename with a second command chained onto it" {
  out="$(NM_GATE=1 bash_out "mv docs/adr/0007-x.md docs/adr/0009-x.md && rm docs/adr/0001-y.md")"
  equals "$(decision_of "$out")" "deny"
}

@test "NM_GATE denies a rename carrying a flag" {
  out="$(NM_GATE=1 bash_out "mv -f docs/adr/0007-x.md docs/adr/0009-x.md")"
  equals "$(decision_of "$out")" "deny"
}

@test "NM_GATE lets a digits-only edit through" {
  out="$(NM_GATE=1 edit_out "# 0007. Cache the index" "# 0009. Cache the index")"
  is_empty "$(decision_of "$out")"
  contains "$(context_of "$out")" "ADR renumber"
}

@test "NM_GATE denies an edit that changes a word alongside the number" {
  out="$(NM_GATE=1 edit_out "# 0007. Cache the index" "# 0009. Cache the manifest")"
  equals "$(decision_of "$out")" "deny"
}

@test "an interactive rename gets the renumber guidance, not amend/supersede" {
  out="$(bash_out "git mv docs/adr/0007-x.md docs/adr/0009-x.md")"
  contains "$(context_of "$out")" "ADR renumber"
  lacks "$(context_of "$out")" "Supersede it"
}

@test "a write outside docs/adr is untouched" {
  out="$(hook_out Write "$TMP/not-adr/README.md")"
  is_empty "$out"
}

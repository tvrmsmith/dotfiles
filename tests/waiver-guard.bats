load helpers/assert

HOOK="${BATS_TEST_DIRNAME}/../dot-claude/hooks/waiver-guard.sh"
LOG="/Users/x/.local/state/coding-standards/waivers.jsonl"
WAIVE='/Users/x/.cache/coding-standards/lint-changed waive --language csharp --path src/A.cs --rule TVRM0006 --reason "doc comment"'

setup() {
  # An armed /afk on this machine would turn every interactive case unattended.
  export HOME="$(mktemp -d)"
  mkdir -p "$HOME/.claude"
}
teardown() { rm -rf "$HOME"; }

# Pipes a Bash payload carrying command $1.
bash_out() {
  jq -n --arg v "$1" '{tool_name: "Bash", tool_input: {command: $v}}' | bash "$HOOK"
}

# Pipes a file-tool payload for tool $1 against path $2.
file_out() {
  jq -n --arg t "$1" --arg v "$2" '{tool_name: $t, tool_input: {file_path: $v}}' | bash "$HOOK"
}

decision_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.permissionDecision // empty'; }

@test "the printed waive command asks for approval" {
  out="$(CLAUDE_CODE_ENTRYPOINT=cli bash_out "$WAIVE")"
  equals "$(decision_of "$out")" "ask"
}

@test "a quoted binary path still asks" {
  out="$(CLAUDE_CODE_ENTRYPOINT=cli bash_out '"/a b/lint-changed" waive --language go --rule x --reason y')"
  equals "$(decision_of "$out")" "ask"
}

context_of() { printf '%s' "$1" | jq -r '.hookSpecificOutput.additionalContext // empty'; }

@test "a headless or SDK run is allowed and told the waiver is reviewed at the end" {
  for entry in sdk-cli sdk-ts; do
    out="$(CLAUDE_CODE_ENTRYPOINT=$entry bash_out "$WAIVE")"
    is_empty "$(decision_of "$out")"
    contains "$(context_of "$out")" "approves it at the end"
  done
}

@test "an armed /afk session is allowed, an expired one asks" {
  echo $(( $(date +%s) + 3600 )) > "$HOME/.claude/afk"
  out="$(CLAUDE_CODE_ENTRYPOINT=cli bash_out "$WAIVE")"
  is_empty "$(decision_of "$out")"
  echo $(( $(date +%s) - 60 )) > "$HOME/.claude/afk"
  out="$(CLAUDE_CODE_ENTRYPOINT=cli bash_out "$WAIVE")"
  equals "$(decision_of "$out")" "ask"
}

@test "unattended runs still cannot hand-write the log" {
  out="$(CLAUDE_CODE_ENTRYPOINT=sdk-ts bash_out "echo x >> $LOG")"
  equals "$(decision_of "$out")" "deny"
}

@test "listing waivers and reading the log stay open" {
  out="$(bash_out '/x/lint-changed waivers')"
  is_empty "$(decision_of "$out")"
  out="$(bash_out "cat $LOG")"
  is_empty "$(decision_of "$out")"
}

@test "a lint run that is not a waive stays open" {
  out="$(bash_out 'lint-changed --staged')"
  is_empty "$(decision_of "$out")"
}

@test "hand-writing the log by redirect or tee is denied" {
  out="$(bash_out "echo '{}' >> $LOG")"
  equals "$(decision_of "$out")" "deny"
  out="$(bash_out "echo '{}' | tee -a $LOG")"
  equals "$(decision_of "$out")" "deny"
}

@test "hand-writing the log with a file tool is denied" {
  for t in Edit Write MultiEdit; do
    out="$(file_out "$t" "$LOG")"
    equals "$(decision_of "$out")" "deny"
  done
}

@test "an ordinary file write stays open" {
  out="$(file_out Write "$HOME/notes/waivers.md")"
  is_empty "$(decision_of "$out")"
}

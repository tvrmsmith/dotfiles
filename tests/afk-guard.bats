load helpers/assert

HOOK="${BATS_TEST_DIRNAME}/../dot-claude/hooks/afk-guard.sh"

setup() {
  TMP="$(mktemp -d)"
  export HOME="$TMP"
  mkdir -p "$HOME/.claude/afk-sessions"
  SESSION="sess-1"
  MARK="$HOME/.claude/afk-sessions/$SESSION"
  : > "$MARK"
  TRANSCRIPT="$TMP/transcript.jsonl"
}
teardown() { rm -rf "$TMP"; }

# The marker assertions go through a helper for the reason helpers/assert.bash
# gives: only a test's last command grades it, so a bare [ -f ] mid-body cannot
# fail.
marker_present() { [ -f "$MARK" ] || { printf 'expected the session marker to survive\n' >&2; exit 1; }; }
marker_cleared() { [ -f "$MARK" ] && { printf 'expected the session marker to be cleared\n' >&2; exit 1; }; return 0; }

# Appends a user row to the transcript with the given promptId, promptSource,
# and origin.kind (pass "null" for no origin object).
transcript_row() {
  local prompt_id="$1" source="$2" kind="$3" origin
  if [ "$kind" = "null" ]; then
    origin='null'
  else
    origin="$(jq -n --arg k "$kind" '{kind: $k}')"
  fi
  jq -nc --arg pid "$prompt_id" --arg src "$source" --argjson origin "$origin" \
    '{type: "user", promptId: $pid, promptSource: $src, origin: $origin}' >> "$TRANSCRIPT"
}

# Pipes a UserPromptSubmit payload at the hook, returning its raw stdout.
submit() {
  jq -n --arg sid "$SESSION" --arg pid "$1" --arg tp "$TRANSCRIPT" \
    '{hook_event_name: "UserPromptSubmit", session_id: $sid, prompt_id: $pid, transcript_path: $tp, prompt: "hi"}' \
    | bash "$HOOK"
}

@test "a typed prompt announces the return and clears the marker" {
  transcript_row "p1" "typed" "human"
  out="$(submit "p1")"
  contains "$out" "Trevor is back"
  marker_cleared
}

@test "a background task-notification stays silent and leaves the marker" {
  transcript_row "p1" "system" "task-notification"
  out="$(submit "p1")"
  is_empty "$out"
  marker_present
}

@test "a peer session message stays silent and leaves the marker" {
  transcript_row "p1" "system" "peer"
  out="$(submit "p1")"
  is_empty "$out"
  marker_present
}

@test "no matching transcript row stays silent and leaves the marker" {
  # Transcript has a row, but not for this prompt_id.
  transcript_row "some-other-id" "typed" "human"
  out="$(submit "p1")"
  is_empty "$out"
  marker_present
}

@test "an unreadable transcript stays silent and leaves the marker" {
  rm -f "$TRANSCRIPT"
  out="$(submit "p1")"
  is_empty "$out"
  marker_present
}

@test "no marker for this session means no announcement even for a typed prompt" {
  rm -f "$MARK"
  transcript_row "p1" "typed" "human"
  out="$(submit "p1")"
  is_empty "$out"
}

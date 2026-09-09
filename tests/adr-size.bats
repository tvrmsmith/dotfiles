load helpers/assert

HOOK="${BATS_TEST_DIRNAME}/../dot-claude/hooks/adr-size.sh"

setup() {
  TMP="$(mktemp -d)"
  ADR_DIR="$TMP/docs/adr"
  mkdir -p "$ADR_DIR"
}
teardown() { rm -rf "$TMP"; }

# Runs the hook against a Write of $2 to file $1, returns the additionalContext
# string (empty if the hook stayed silent).
write_context() {
  jq -n --arg fp "$1" --arg c "$2" \
    '{tool_name: "Write", tool_input: {file_path: $fp, content: $c}}' \
    | bash "$HOOK" | jq -r '.hookSpecificOutput.additionalContext // empty'
}

edit_context() {
  jq -n --arg fp "$1" --arg old "$2" --arg new "$3" \
    '{tool_name: "Edit", tool_input: {file_path: $fp, old_string: $old, new_string: $new}}' \
    | bash "$HOOK" | jq -r '.hookSpecificOutput.additionalContext // empty'
}

words() { printf 'word %.0s' $(seq 1 "$1"); }

@test "an ADR with no decision block is nudged" {
  result="$(write_context "$ADR_DIR/0001-x.md" "# Title

Body with no heading of that name.")"
  contains "$result" 'No `## Current rule` or `## Decision` block'
}

@test "a Current rule block satisfies the decision-block check" {
  result="$(write_context "$ADR_DIR/0001-x.md" "# Title

## Current rule

Short and fine.")"
  is_empty "$result"
}

@test "a Decision block satisfies the decision-block check" {
  result="$(write_context "$ADR_DIR/0001-x.md" "# Title

## Status

Accepted

## Decision

Short and fine.

## Consequences

stuff")"
  is_empty "$result"
}

@test "a Current rule block over the limit is nudged with the count" {
  result="$(write_context "$ADR_DIR/0001-x.md" "# Title

## Current rule

$(words 500)

## Considered options

stuff")"
  contains "$result" 'runs 500 words against a 400 limit'
}

@test "a Decision block over the limit is nudged, later sections excluded from the count" {
  result="$(write_context "$ADR_DIR/0001-x.md" "# Title

## Decision

$(words 500)

## Consequences

$(words 300)")"
  contains "$result" 'runs 500 words against a 400 limit'
}

@test "a block under the limit is not nudged for length" {
  result="$(write_context "$ADR_DIR/0001-x.md" "# Title

## Decision

$(words 399)")"
  is_empty "$result"
}

@test "a file over the word limit is nudged, block under the limit" {
  result="$(write_context "$ADR_DIR/0001-x.md" "# Title

## Decision

$(words 100)

## Consequences

$(words 2500)")"
  contains "$result" 'consider superseding'
}

@test "a file under the word limit with a short block stays silent" {
  result="$(write_context "$ADR_DIR/0001-x.md" "# Title

## Decision

$(words 100)

## Consequences

$(words 1000)")"
  is_empty "$result"
}

@test "editing an old-style ADR that never had a decision block is not nudged for lacking one" {
  old_file="$ADR_DIR/0005-old.md"
  printf '# Old ADR\n\nSome reasoning with no decision heading.\n\nTail text.\n' > "$old_file"
  result="$(edit_context "$old_file" "Tail text." "Tail text, corrected.")"
  is_empty "$result"
}

@test "an edit that deletes an existing decision block is nudged" {
  live_file="$ADR_DIR/0001-live.md"
  printf '# Live ADR\n\n## Decision\n\nThe rule text.\n\n## Consequences\n\nstuff\n' > "$live_file"
  result="$(edit_context "$live_file" "## Decision

The rule text." "Just some prose, no heading.")"
  contains "$result" 'No `## Current rule` or `## Decision` block'
}

@test "five Amended paragraphs trip the consolidation nudge under the word limit" {
  live_file="$ADR_DIR/0001-live.md"
  printf '# Live ADR\n\n## Decision\n\nThe rule text.\n\nTail sentence.\n' > "$live_file"
  entries=""
  for i in 1 2 3 4 5; do
    entries="${entries}**Amended 2026-09-0${i}.** Note ${i}.

"
  done
  result="$(edit_context "$live_file" "Tail sentence." "${entries}Tail sentence.")"
  contains "$result" '5 dated entries'
}

@test "five dated Changelog bullets trip the same nudge" {
  live_file="$ADR_DIR/0001-live.md"
  printf '# Live ADR\n\n## Decision\n\nThe rule text.\n\n## Changelog\n\nTail sentence.\n' > "$live_file"
  entries=""
  for i in 1 2 3 4 5; do
    entries="${entries}- **2026-08-0${i}** Note ${i}.
"
  done
  result="$(edit_context "$live_file" "Tail sentence." "$entries")"
  contains "$result" '5 dated entries'
}

@test "four dated entries under the word limit do not trip the nudge" {
  live_file="$ADR_DIR/0001-live.md"
  printf '# Live ADR\n\n## Decision\n\nThe rule text.\n\nTail sentence.\n' > "$live_file"
  entries=""
  for i in 1 2 3 4; do
    entries="${entries}**Amended 2026-09-0${i}.** Note ${i}.

"
  done
  result="$(edit_context "$live_file" "Tail sentence." "${entries}Tail sentence.")"
  is_empty "$result"
}

@test "an ADR marked superseded by a paragraph is frozen, never linted" {
  result="$(write_context "$ADR_DIR/0003-old.md" "# Old ADR

**Superseded 2026-09-01 by [ADR 0007](0007-x.md)**

## Decision

$(words 3000)")"
  is_empty "$result"
}

@test "an ADR marked superseded by a Status line is frozen, never linted" {
  result="$(write_context "$ADR_DIR/0003-old.md" "# Old ADR

- **Status:** Superseded by ADR-0013 (2026-07-09)

## Decision

$(words 3000)")"
  is_empty "$result"
}

@test "prose arguing something was superseded does not freeze a live ADR" {
  result="$(write_context "$ADR_DIR/0001-live.md" "# Live ADR

## Decision

The header approach is
  superseded. A client-supplied header is spoofable.

$(words 3000)")"
  contains "$result" 'consider superseding'
}

@test "the ADR directory README is an index, never linted" {
  result="$(write_context "$ADR_DIR/README.md" "# Architecture Decision Records

An index with no decision block and $(words 3000)")"
  is_empty "$result"
}

@test "an ADR under a nested service directory is linted" {
  nested="$TMP/src/platform/core/payer/docs/adr"
  mkdir -p "$nested"
  result="$(write_context "$nested/0001-x.md" "# Title

Body with no heading of that name.")"
  contains "$result" 'No `## Current rule` or `## Decision` block'
}

@test "ADR_BLOCK_WORDS tightens the block limit" {
  export ADR_BLOCK_WORDS=100
  result="$(write_context "$ADR_DIR/0001-x.md" "# Title

## Decision

$(words 200)")"
  contains "$result" 'runs 200 words against a 100 limit'
}

@test "NM_GATE silences the hook, adr-guard already denied that write" {
  export NM_GATE=1
  result="$(write_context "$ADR_DIR/0001-x.md" "# Title

Body with no heading of that name.")"
  is_empty "$result"
}

@test "a write outside docs/adr is untouched" {
  result="$(write_context "$TMP/not-adr/README.md" "no decision block here at all")"
  is_empty "$result"
}

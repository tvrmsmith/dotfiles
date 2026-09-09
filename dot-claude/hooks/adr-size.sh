#!/usr/bin/env bash
#
# adr-size.sh — PreToolUse size lint for ADRs, in any repo.
#
# An ADR grows quietly, one amendment at a time, until the decision is buried in
# its own changelog. This reports the counts at the moment of the write.
#
# Three checks, all nudges and never a deny. A block lands on the write itself,
# and a write mid-way through drafting an ADR is exactly the write a wrong block
# would hit:
#
#   1. The file states its decision under a heading a reader can find.
#   2. That block stays under BLOCK_WORDS.
#   3. The file stays under FILE_WORDS, and carries under AMENDMENTS
#      date-stamped entries.
#
# Nothing here is keyed to one repo's template. The block heading matches either
# name in general ADR use, `## Current rule` or `## Decision`, and the amendment
# counter matches any line-leading `**YYYY-MM-DD`, which is both the standalone
# amendment paragraph and the dated bullet under a `## Changelog`. Measured
# against a ~200-ADR repo those cover all but three files.
#
# The limits are deliberately looser than any one repo's house rule, so the
# nudge marks real bloat rather than firing on a quarter of ordinary writes. A
# repo is free to hold itself to a stricter number in prose. Override either
# without editing this file by exporting ADR_BLOCK_WORDS / ADR_FILE_WORDS.
#
# adr-guard.sh is the separate concern on the same paths: who may write an ADR
# at all. It denies every no-mistakes gate write, so this hook stays quiet under
# NM_GATE rather than annotating a write that is already refused.
#
# Reconstructing the resulting file from Edit/MultiEdit is best-effort; a
# failure to read or replay it skips the checks rather than blocking.
#
# Wired in dot-claude/settings.json under PreToolUse.

set -uo pipefail

BLOCK_WORDS="${ADR_BLOCK_WORDS:-400}"
FILE_WORDS="${ADR_FILE_WORDS:-2500}"
AMENDMENTS="${ADR_AMENDMENTS:-5}"

BLOCK_RE='^## (Current rule|Decision)([[:space:]]|$)'
AMENDMENT_RE='^[-*]?[[:space:]]*\*\*(Amended )?[0-9]{4}-[0-9]{2}-[0-9]{2}'

[ "${NM_GATE:-}" = 1 ] && exit 0

payload="$(cat)"

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
case "$tool" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

file="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
[ -n "$file" ] || exit 0

# Every ADR lives in a `docs/adr/` directory, at the repo root or under a
# service/product subtree. Match the segment, not any one location.
printf '%s' "$file" | grep -Eq '(^|/)docs/adr/' || exit 0

# The README in an ADR directory is the index of the decisions, not one of them.
# It has no decision block and it grows a line per ADR by design.
[ "$(basename "$file")" = "README.md" ] && exit 0

# Best-effort reconstruction of the file the checks apply to, from a PreToolUse
# payload that has not landed yet. Write carries the whole content already.
# Edit/MultiEdit carry a diff against the file on disk, so each edit is replayed
# with a literal (not glob or regex) substitution. Anything this cannot resolve
# — a MultiEdit against a file that does not yet exist, an old_string absent
# from the file — prints nothing, and the caller treats empty as "skip".
resulting_content() {
  local tool="$1" payload="$2"
  case "$tool" in
    Write)
      printf '%s' "$payload" | jq -r '.tool_input.content // empty'
      ;;
    Edit|MultiEdit)
      local file edits n i old new all tmp
      file="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty')"
      [ -n "$file" ] && [ -f "$file" ] || return 0
      if [ "$tool" = "Edit" ]; then
        edits="$(printf '%s' "$payload" | jq -c '
          [{old_string: .tool_input.old_string, new_string: .tool_input.new_string,
            replace_all: (.tool_input.replace_all // false)}]')"
      else
        edits="$(printf '%s' "$payload" | jq -c '.tool_input.edits // []')"
      fi
      n="$(printf '%s' "$edits" | jq 'length')"
      tmp="$(mktemp)" || return 0
      cp "$file" "$tmp"
      for ((i = 0; i < n; i++)); do
        old="$(printf '%s' "$edits" | jq -r ".[$i].old_string // empty")"
        new="$(printf '%s' "$edits" | jq -r ".[$i].new_string // empty")"
        all="$(printf '%s' "$edits" | jq -r ".[$i].replace_all // false")"
        perl -0777 -e '
          my ($old, $new, $all) = @ARGV;
          local $/; my $c = <STDIN>;
          my $q = quotemeta($old);
          if ($all eq "true") { $c =~ s/$q/$new/g } else { $c =~ s/$q/$new/ }
          print $c;
        ' "$old" "$new" "$all" <"$tmp" >"$tmp.next" 2>/dev/null && mv "$tmp.next" "$tmp"
      done
      cat "$tmp"
      rm -f "$tmp" "$tmp.next"
      ;;
  esac
}

# A superseded ADR is frozen: its replacement carries the rule, and the
# convention in both templates is to leave the old file untouched. Telling it to
# consolidate is advice about a file nobody should be editing. Marked either as
# a standalone `**Superseded ...**` paragraph or a Status line naming the
# replacement, so only the header is scanned and prose arguing that something
# was superseded does not count.
is_superseded() {
  printf '%s' "$1" | head -25 \
    | grep -Eqi '^([-*][[:space:]])?(\*\*)?(superseded|status[:*[:space:]]+.*superseded)'
}

has_block() {
  printf '%s' "$1" | grep -Eq "$BLOCK_RE"
}

# Word count of the decision block: its heading line to the next `## ` heading
# or end of file, the heading itself excluded.
block_words() {
  printf '%s' "$1" | awk -v re="$BLOCK_RE" '
    found && /^## / { exit }
    found { print }
    $0 ~ re { found = 1 }
  ' | wc -w | tr -d ' '
}

amendment_count() {
  printf '%s' "$1" | grep -cE "$AMENDMENT_RE"
}

size_notes() {
  local new_content="$1" old_content="$2" notes="" words total amendments

  is_superseded "$new_content" && return 0

  # A file that already lacked a decision block before this write predates the
  # convention, and an edit to it is not the moment to retrofit structure.
  if ! has_block "$new_content"; then
    if [ -z "$old_content" ] || has_block "$old_content"; then
      notes="${notes}No \`## Current rule\` or \`## Decision\` block. State the decision under one heading a reader can find. "
    fi
  else
    words="$(block_words "$new_content")"
    if [ "$words" -gt "$BLOCK_WORDS" ]; then
      notes="${notes}The decision block runs $words words against a $BLOCK_WORDS limit. It is what a reader reads in full, so a decision that will not fit is more than one decision. "
    fi
  fi

  total="$(printf '%s' "$new_content" | wc -w | tr -d ' ')"
  amendments="$(amendment_count "$new_content")"
  if [ "$total" -gt "$FILE_WORDS" ] || [ "$amendments" -ge "$AMENDMENTS" ]; then
    notes="${notes}The file runs $total words with $amendments dated entries, against limits of $FILE_WORDS and $AMENDMENTS. Past that a reader reconstructs the rule from a changelog; consider superseding with a new ADR. "
  fi

  printf '%s' "${notes% }"
}

new_content="$(resulting_content "$tool" "$payload")"
[ -n "$new_content" ] || exit 0

old_content=""
[ -f "$file" ] && old_content="$(cat "$file")"

notes="$(size_notes "$new_content" "$old_content")"
[ -n "$notes" ] || exit 0

# No permissionDecision: the call keeps going through the normal permission
# flow, carrying the counts into the decision.
jq -n --arg r "ADR size. $notes" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $r
  }
}'

exit 0

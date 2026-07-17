#!/bin/bash
# bd-close-guard.sh — Claude Code PreToolUse (Bash) guard.
#
# Blocks `bd close` on a decision/spike bead whose output was not made durable
# and routed to the work that consumes it. Only committed or bd-synced state
# crosses worktree/agent boundaries; a bare filesystem path or an unpromoted
# design field silently evaporates when an ephemeral worktree is cleaned up.
#
# Three checks for each closing bead with issue_type in {decision, spike}:
#
#   1. PROMOTION — the child id must appear in its PARENT's authored text
#      (description/notes/design), so the consumer is routed through the result.
#      The parent's structural sections (CHILDREN, DEPENDS ON, ...) auto-list
#      the child id, so they are stripped before searching.
#
#   2. PROTOTYPE COMMITTED — every `Prototype: <sha>:<path>` pointer recorded in
#      the bead must resolve to a committed object (git cat-file -e; <path> is a
#      file or a directory tree — a prototype may be many files under
#      prototypes/<bead-id>/). Catches the exact failure mode: a path recorded
#      but the bytes never committed.
#
#   3. PROTOTYPE POINTER PROMOTED — the prototype path must also appear in the
#      parent's authored text, so the parent/build can find the mock.
#
# Everything else (other types, parentless decisions, beads with no prototype)
# passes untouched. Registered per-repo in .claude/settings.local.json.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
command -v bd >/dev/null 2>&1 || exit 0

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -n "$CMD" ] || exit 0

# Only care about `bd close ...`.
printf '%s' "$CMD" | grep -Eq '(^|[;&|[:space:]])bd[[:space:]]+close([[:space:]]|$)' || exit 0

# Collect candidate bead ids: everything after `bd close`, keep only tokens that
# look like bead ids (prefix-slug, optional .N child suffix), drop flags/values.
IDS=$(printf '%s' "$CMD" \
  | sed -n 's/.*bd[[:space:]]\{1,\}close[[:space:]]\{1,\}//p' \
  | tr ' ' '\n' \
  | grep -E '^[a-zA-Z][a-zA-Z0-9]*-[a-zA-Z0-9]+(\.[0-9]+)?$' || true)
[ -n "$IDS" ] || exit 0

REPO=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")

# Strip a bead's structural relationship sections; leave authored content.
authored_text() {
  bd show "$1" 2>/dev/null | awk '
    /^[A-Z][A-Z ]+$/ {
      sec=$0
      skip=(sec=="CHILDREN"||sec=="DEPENDS ON"||sec=="BLOCKS"||sec=="PARENT" \
            ||sec=="BLOCKED BY"||sec=="RELATED TO"||sec=="DISCOVERED FROM")
      next
    }
    !skip { print }
  '
}

# Emit each `Prototype: <ref>:<path>` pointer recorded in a bead as "<ref>:<path>".
proto_pointers() {
  authored_text "$1" \
    | grep -ioE 'prototype:[[:space:]]*[^[:space:]]+:[^[:space:]]+' \
    | sed -E 's/^[Pp]rototype:[[:space:]]*//' || true
}

VIOLATIONS=""
for id in $IDS; do
  JSON=$(bd show "$id" --json 2>/dev/null) || continue
  read -r TYPE PARENT < <(printf '%s' "$JSON" | jq -r '
    (if type=="array" then .[0] else . end) | "\(.issue_type // "") \(.parent // "")"')
  case "$TYPE" in decision|spike) ;; *) continue ;; esac

  HAS_PARENT=0
  [ -n "$PARENT" ] && [ "$PARENT" != "null" ] && HAS_PARENT=1
  [ "$HAS_PARENT" = 1 ] && PARENT_TEXT=$(authored_text "$PARENT") || PARENT_TEXT=""

  # 1. Promotion of the decision into the parent.
  if [ "$HAS_PARENT" = 1 ] && ! printf '%s' "$PARENT_TEXT" | grep -qF "$id"; then
    VIOLATIONS="${VIOLATIONS}  - $id ($TYPE): result not promoted — parent $PARENT does not reference it\n"
  fi

  # 2 + 3. Prototype pointers: committed, and promoted to parent.
  while IFS= read -r ptr; do
    [ -n "$ptr" ] || continue
    REF="${ptr%%:*}"
    PPATH="${ptr#*:}"
    if ! git -C "$REPO" cat-file -e "${REF}:${PPATH}" 2>/dev/null; then
      VIOLATIONS="${VIOLATIONS}  - $id ($TYPE): prototype not committed — cannot resolve ${REF}:${PPATH}\n"
    fi
    if [ "$HAS_PARENT" = 1 ] && ! printf '%s' "$PARENT_TEXT" | grep -qF "$PPATH"; then
      VIOLATIONS="${VIOLATIONS}  - $id ($TYPE): prototype pointer not promoted — parent $PARENT missing $PPATH\n"
    fi
  done < <(proto_pointers "$id")
done

[ -n "$VIOLATIONS" ] || exit 0

REASON=$(printf 'bd close blocked — decision/spike output not durable/routed:\n%bFix before close: commit the prototype dir prototypes/<bead-id>/ (may hold multiple files), record `Prototype: <sha>:prototypes/<bead-id>/` in the bead, and promote the decision + that pointer into the parent (e.g. `bd note <parent> ...` / `bd update <parent> --design-file`). Then retry.' "$VIOLATIONS")

jq -n --arg r "$REASON" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0

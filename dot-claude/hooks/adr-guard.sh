#!/usr/bin/env bash
#
# adr-guard.sh. PreToolUse guard for ADR directories.
#
# ADRs record decisions that were already made. Rewriting one is a decision
# change, not a code fix, so it is never something an automated review pass
# should do on its own. The no-mistakes review step did it 12 times to a single
# accepted ADR on one branch; every rewrite was editorial, none changed the
# decision.
#
# A renumber is the exception, because it carries no decision. An ADR numbered
# 0007 on a branch collides with a 0007 that landed on main, and the fix is
# mechanical: rename the file, then follow the number through the title, the
# index, and every link. Blocking that leaves the gate agent stuck on a clash it
# can resolve correctly.
#
# Behaviour depends on who is running:
#
#   NM_GATE=1 (set by nm-claude, i.e. a no-mistakes gate step agent)
#     read     -> guidance injected, normal permission flow
#     renumber -> guidance injected, normal permission flow
#     write    -> DENY
#
#   interactive session (no NM_GATE)
#     every access -> guidance injected, normal permission flow
#
# Anything not touching an ADR path exits silently and costs nothing.
#
# Edit/Write/MultiEdit/NotebookEdit is the surface this covers reliably. Bash is
# classified by pattern, so an unusual writer (an inline python or node script)
# still gets through.
#
# Wired in dot-claude/settings.json under PreToolUse.

set -uo pipefail

payload="$(cat)"

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
[ -n "$tool" ] || exit 0

# Every ADR lives in a `docs/adr/` directory, at the repo root or under a
# service/product subtree. Match the segment, not any one location. The leading
# class also has to admit a path sitting mid-command-line (`rm docs/adr/x`).
ADR_RE='(^|[^[:alnum:]_-])docs/adr/'

case "$tool" in
  Read|Edit|Write|MultiEdit|NotebookEdit)
    target="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
    ;;
  Bash)
    target="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
    ;;
  *)
    exit 0
    ;;
esac

[ -n "$target" ] || exit 0
printf '%s' "$target" | grep -Eq "$ADR_RE" || exit 0

cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty')"
[ -n "$cwd" ] || cwd="$PWD"

# True when the command is one `mv` or `git mv` renaming a .md file within a
# single docs/adr directory, onto a name nothing occupies yet. A subshell, so
# `set -f` (no globbing while word-splitting) and the `cd` are both local.
#
# Every condition is a way the command could be doing something other than
# renaming: shell composition chains a second command, a flag reaches -f, two
# directories make it a move out of the ADR set, an existing destination
# overwrites an accepted ADR. Whatever this cannot read as plainly a rename
# falls through to the write rules, so the failure is a deny, never an allow.
is_adr_rename() (
  set -f
  local cmd="$1" root="$2" src dst p
  printf '%s' "$cmd" | grep -Eq '[;&|<>`$()'"'"'"]' && return 1
  # shellcheck disable=SC2086  # word splitting is the point, globbing is off
  set -- $cmd
  [ "${1:-}" = "git" ] && shift
  [ "${1:-}" = "mv" ] || return 1
  shift
  [ "$#" -eq 2 ] || return 1
  src="$1"
  dst="$2"
  for p in "$src" "$dst"; do
    printf '%s' "$p" | grep -Eq "$ADR_RE" || return 1
    case "$p" in *.md) ;; *) return 1 ;; esac
  done
  [ "$src" != "$dst" ] || return 1
  [ "$(dirname "$src")" = "$(dirname "$dst")" ] || return 1
  cd "$root" 2>/dev/null || return 1
  [ ! -e "$dst" ]
)

# True when every replacement in the payload is identical once digits are
# stripped, so the edit can only move numbers around. That admits the title
# line, an index entry, and a link target; it refuses any change to the prose
# stating the decision.
is_digit_only_edit() {
  printf '%s' "$1" | jq -e '
    (if .tool_name == "Edit"
     then [{old: (.tool_input.old_string // ""), new: (.tool_input.new_string // "")}]
     else [.tool_input.edits[]? | {old: (.old_string // ""), new: (.new_string // "")}]
     end)
    | length > 0
      and all(.[]; .old != .new and (.old | gsub("[0-9]"; "")) == (.new | gsub("[0-9]"; "")))
  ' >/dev/null 2>&1
}

# Classify the access as read, renumber, or write.
case "$tool" in
  Read)
    access="read"
    ;;
  Edit|MultiEdit)
    if is_digit_only_edit "$payload"; then
      access="renumber"
    else
      access="write"
    fi
    ;;
  Write|NotebookEdit)
    access="write"
    ;;
  Bash)
    if is_adr_rename "$target" "$cwd"; then
      access="renumber"
    # Otherwise a shell command is a write only if it actually mutates. Plain
    # inspection (cat, rg, git log, git show, ls) stays a read so the guard does
    # not obstruct the reading an ADR is there for.
    elif printf '%s' "$target" | grep -Eq '(>>?[[:space:]]*[^|&;]*docs/adr/|[[:space:]]tee[[:space:]]|sed[[:space:]]+-[a-zA-Z]*i|\bperl\b[^|]*-[a-zA-Z]*i|\b(rm|mv|cp|truncate|install)\b|git[[:space:]]+(apply|checkout|restore|mv|rm)\b|\bpatch\b)'; then
      access="write"
    else
      access="read"
    fi
    ;;
esac

deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
}

# No permissionDecision: the call keeps going through the normal permission
# flow. Deciding "allow" here would suppress the prompt this guard exists to
# make more informed.
guide() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $r
    }
  }'
}

READ_GUIDANCE='ADR directory. An ADR is a decision already made, not a draft. Read it as a constraint on the change under review: code that contradicts it is the finding, the ADR is not. If the ADR itself looks wrong, that is a decision to escalate to the user, not an edit to make.'

WRITE_GUIDANCE='ADR directory. An accepted ADR changes two ways. Amend it, with a dated paragraph placed next to the text it corrects, when the decision stands and the text is wrong. Supersede it, with a new numbered ADR stating the rule in one pass, when the decision itself changes. The existing text stays as written either way. Confirm with the user which of the two this is before writing.'

RENUMBER_GUIDANCE='ADR renumber. A rename, or an edit that only moves digits, changes no decision, so it goes through here. Carry the new number across the whole set in this same pass: the filename, the number in the title, the index line in the ADR README, and every link naming the old number. Leave every other word of the file as written.'

GATE_DENY='Blocked: no-mistakes gate agents do not write ADRs. An ADR is a decision the user already made; changing it is the user'"'"'s call, not a review fix. Both paths are human-initiated: amend for a correction, supersede with a new numbered ADR when the decision changes. If the diff genuinely contradicts an accepted ADR, report that as a finding against the CODE and let it reach the user. Leave every file under docs/adr/ exactly as it stands. One exception passes: a renumber after a number clash, which is a `mv` within the ADR directory plus edits that alter digits and nothing else.'

if [ "$access" = "write" ] && [ "${NM_GATE:-}" = 1 ]; then
  deny "$GATE_DENY"
  exit 0
fi

case "$access" in
  write) guide "$WRITE_GUIDANCE" ;;
  renumber) guide "$RENUMBER_GUIDANCE" ;;
  *) guide "$READ_GUIDANCE" ;;
esac

exit 0

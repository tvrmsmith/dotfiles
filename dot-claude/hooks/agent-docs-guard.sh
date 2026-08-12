#!/usr/bin/env bash
#
# agent-docs-guard.sh — PreToolUse nudge toward the `writing-for-agents` skill.
#
# A document an agent consumes is a different craft from prose for humans, and
# the skill that encodes that craft is model-invocable but rarely invoked: across
# every transcript on this machine it fired 7 times, versus 47 for the old
# `writing-great-skills` name it replaced. The CLAUDE.md rule states the
# expectation; this hook is what makes it land at the moment of the edit, when
# the instruction is actually actionable.
#
# Guidance only — never a deny. Writing one of these files is legitimate; the
# only claim here is that it should be done with the skill loaded.
#
# Fires once per session, tracked by a marker under
# $TMPDIR/claude-agent-docs-guard/. Repeating it on every edit of a long
# SKILL.md rewrite would be pure noise, and the skill stays loaded once read.
#
# A repo can widen the match by committing `.claude/agent-docs-paths`: one
# extended-regex per line, matched against the target path, `#` comments and
# blank lines ignored. That covers the files this hook cannot recognise by name
# — a REFERENCE.md that is agent-facing only because it sits in a skill
# directory. Kept as a repo file rather than a second hook so both sources share
# one per-session marker and the nudge still lands only once.
#
# Wired in dot-claude/settings.json under PreToolUse.

set -uo pipefail

payload="$(cat)"

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty')"
case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac

target="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
[ -n "$target" ] || exit 0

# Filenames that are agent-facing by convention, plus the `agents/` sidecar dirs
# the Matt Pocock skills use for per-harness metadata. A `docs/` file reached by
# a pointer is agent-facing too, but nothing in its path says so — CLAUDE.md
# covers that case, this hook cannot.
AGENT_DOC_RE='(^|/)(SKILL(-[A-Z-]+)?\.md|AGENTS?\.md|CLAUDE(\.local)?\.md|GEMINI\.md|\.cursorrules)$|(^|/)agents/[^/]+\.(yaml|yml)$|\.mdc$'

# Harness config directories. Everything inside one exists to be read by an
# agent, whatever the file is called — a skill's REFERENCE.md, a command, a
# subagent definition, a helper script a skill shells out to. These names are
# claimed by the harness, so matching the whole subtree is safe in any repo;
# a bare `skills/` is not, and stays a per-repo opt-in.
AGENT_DIR_RE='(^|/)\.(claude|codex|agents|cursor|gemini)/'

# Machine-read config and generated state live in those same directories and are
# not writing at all. Nudging on a settings.json permission edit would spend the
# one nudge this hook gets per session on the one file where the skill has
# nothing to say.
AGENT_DIR_EXCLUDE_RE='(^|/)\.(claude|codex|agents|cursor|gemini)/(settings([.]local)?[.]json|[^/]*[.](log|lock)|(logs|backups|telemetry|projects|todos|shell-snapshots|statsig|plugins/(cache|marketplaces))/)'

matched=0
if printf '%s' "$target" | grep -Eq "$AGENT_DOC_RE"; then
  matched=1
elif printf '%s' "$target" | grep -Eq "$AGENT_DIR_RE" &&
     ! printf '%s' "$target" | grep -Eq "$AGENT_DIR_EXCLUDE_RE"; then
  matched=1
fi

# Repo-supplied patterns, for agent-facing files this hook cannot name.
extra="${CLAUDE_PROJECT_DIR:-}/.claude/agent-docs-paths"
if [ "$matched" -eq 0 ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -r "$extra" ]; then
  while IFS= read -r pattern || [ -n "$pattern" ]; do
    case "$pattern" in ''|'#'*) continue ;; esac
    if printf '%s' "$target" | grep -Eq "$pattern"; then
      matched=1
      break
    fi
  done <"$extra"
fi

[ "$matched" -eq 1 ] || exit 0

# One nudge per session. session_id is absent in some harnesses; fall back to a
# constant so the marker still dedupes within a run rather than firing per edit.
session="$(printf '%s' "$payload" | jq -r '.session_id // "nosession"')"
marker_dir="${TMPDIR:-/tmp}/claude-agent-docs-guard"
marker="$marker_dir/$session"
mkdir -p "$marker_dir" 2>/dev/null || exit 0
[ -e "$marker" ] && exit 0
: >"$marker"

GUIDANCE='Agent-facing document. Per ~/.claude/CLAUDE.md, load the `writing-for-agents` skill before editing it — writing for an agent is a different craft from writing for a human, and the skill holds the levers that make a document predictable. Load it now unless it is already loaded this session.'

jq -n --arg r "$GUIDANCE" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $r
  }
}'

exit 0

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
# Guidance for an interactive session — never a deny. Writing one of these files
# is legitimate; the only claim there is that it should be done with the skill
# loaded.
#
# One case is a deny instead. Under NM_GATE=1 (set by nm-claude, so the caller is
# a no-mistakes gate step agent) a write to an agent INSTRUCTION file is refused,
# the same shape adr-guard.sh uses for docs/adr/. Those files are the standing
# orders every later step reads, and a gate run amends them unattended: one
# overnight run rewrote AGENTS.md on eight successive restarts, each costing a
# full revalidation. Reads stay open, since AGENTS.md is how the gate agent
# learns the project's rules in the first place. The deny is narrower than the
# nudge: a SKILL.md is agent-facing craft the gate may still fix.
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
  # Bash reaches the gate deny below and nothing else. A shell command carries no
  # single target to nudge about, and the deny is the half that has to hold
  # whatever writes the file.
  Bash) ;;
  *) exit 0 ;;
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

# The instruction files, the subset of the agent-facing set that steers every
# later agent in the repository rather than describing one thing. A no-mistakes
# gate agent amending one of these rewrites the standing orders of the steps
# behind it, inside a run nobody is watching; Trevor keeps them hand-edited.
# Narrower than AGENT_DOC_RE on purpose: a SKILL.md is agent-facing craft the
# gate may still fix.
AGENT_INSTRUCTION_RE='(^|/)(AGENTS?\.md|CLAUDE(\.local)?\.md|GEMINI\.md|\.cursorrules)$'

# The same set recognised inside a shell command line, where the path sits
# between other words instead of alone. The surrounding classes admit `>`, a
# space, or a quote on either side while refusing a longer filename that merely
# ends the same way (`MY-CLAUDE.md`).
AGENT_INSTRUCTION_CMD_RE='(^|[^[:alnum:]_.-])([^[:space:]'"'"'";|&<>]*/)?(AGENTS?\.md|CLAUDE(\.local)?\.md|GEMINI\.md|\.cursorrules)([^[:alnum:]_-]|$)'

GATE_DENY='Blocked: no-mistakes gate agents leave agent instruction files as they stand. AGENTS.md, CLAUDE.md and their siblings are the standing orders every later step reads, so Trevor writes them by hand, in a session he is watching. Report what you wanted to record as a finding instead, naming the file and the exact text you would add, and let it reach him. Every other file in the repository is yours to edit as usual.'

if [ "$tool" = "Bash" ]; then
  [ "${NM_GATE:-}" = 1 ] || exit 0
  command="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')"
  [ -n "$command" ] || exit 0
  printf '%s' "$command" | grep -Eq "$AGENT_INSTRUCTION_CMD_RE" || exit 0
  # Reading one of these is how a gate agent learns the project's rules, so only
  # a command that can mutate is denied. The patterns mirror adr-guard.sh; an
  # unusual writer (an inline python heredoc) still gets through, which is why
  # the deny above covers the file-editing tools directly.
  printf '%s' "$command" | grep -Eq '(>>?[[:space:]]*[^|&;]*(AGENTS?\.md|CLAUDE(\.local)?\.md|GEMINI\.md|\.cursorrules)|[[:space:]]tee[[:space:]]|sed[[:space:]]+-[a-zA-Z]*i|\bperl\b[^|]*-[a-zA-Z]*i|\b(rm|mv|cp|truncate|install)\b|git[[:space:]]+(apply|checkout|restore|mv|rm)\b|\bpatch\b)' || exit 0
  deny "$GATE_DENY"
  exit 0
fi

target="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
[ -n "$target" ] || exit 0

# Ahead of every match below, and ahead of the once-per-session marker: a deny
# has to hold on the tenth edit of a session exactly as it did on the first,
# while the nudge is spent after one.
if [ "${NM_GATE:-}" = 1 ] && printf '%s' "$target" | grep -Eq "$AGENT_INSTRUCTION_RE"; then
  deny "$GATE_DENY"
  exit 0
fi

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

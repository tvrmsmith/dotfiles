#!/usr/bin/env bash
# SessionStart / SubagentStart hook — re-injects the always-apply unslop rules.
#
# The `unslop` skill body is a tool result, so compaction eats it while the
# instruction to follow it survives. That asymmetry is the drift: the agent
# believes it already loaded the rules and no longer holds them. This fires
# on startup, resume, and post-compact, which is exactly when context was
# rebuilt without them. Keep the text short; it lands in every session.
#
# Output protocol: https://docs.claude.com/en/docs/claude-code/hooks
set -euo pipefail

EVENT="SessionStart"
if [ "${1-}" = "--subagent" ]; then
  EVENT="SubagentStart"
fi

RULES='Prose rules (unslop), apply to every reply and every file you write:
1. No em dashes or en dashes. End the sentence or use a comma. Parentheses are not a substitute.
2. No colon as a mid-sentence connector. Before a list is fine.
3. Straight quotes, never curly.
4. No chatbot filler or flattery: "Great question", "Certainly", "Let me know if".
5. Active voice. Name the actor.
6. Plain word over fancy: use, not utilize or leverage. Help, not facilitate.
7. Say the concrete thing. A mechanism, a number, or an instruction, never a feeling.
8. No inflation: crucial, pivotal, testament, landscape, showcase, delve, tapestry.
9. Inverted pyramid. The first two sentences carry the decision, detail descends from there, so stopping early still lands the point.
10. Brevity governs the report, not the work. Investigate the same, write less of it.
11. Close on one next step, or none.
Write clean as you draft. The cleanup pass fails, so never generate the bad sentence.
Editing a document, PR description, or commit body: load the unslop skill for the full checklist.'

# Subagents receive no output style (verified 2026-09-11 by asking one to
# introspect), so the audience note the style would carry has to ride along
# here. Their report goes to an agent, which flips the brevity tradeoff. Padding
# still burns the caller's window, but a truncated finding costs more than a
# long one.
if [ "$EVENT" = "SubagentStart" ]; then
  RULES="$RULES
You report to an agent, not to a person. Give the findings and the evidence behind them in full. Completeness beats brevity here, and the requester decides what happens next, so spend the words on substance rather than preamble, recap, or offers."
fi

jq -n --arg event "$EVENT" --arg ctx "$RULES" '{
  hookSpecificOutput: {
    hookEventName: $event,
    additionalContext: $ctx
  }
}'

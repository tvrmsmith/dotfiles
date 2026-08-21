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
Write clean as you draft. The cleanup pass fails, so never generate the bad sentence.
Editing a document, PR description, or commit body: load the unslop skill for the full checklist.'

jq -n --arg event "$EVENT" --arg ctx "$RULES" '{
  hookSpecificOutput: {
    hookEventName: $event,
    additionalContext: $ctx
  }
}'

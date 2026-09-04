#!/usr/bin/env bash
# Stop hook: while Trevor is AFK, keep a session working instead of letting it
# stop to ask a question nobody is there to answer.
#
# Flag file: $HOME/.claude/afk, containing an expiry epoch (seconds).
#   Present and unexpired -> AFK is on.
#   Expired               -> removed here, AFK is off.
#   Absent                -> hook is a silent no-op.
#
# Exit 0 lets the stop through and shows the agent nothing. Exit 2 blocks the
# stop; stderr becomes the reason the agent reads before continuing.
set -uo pipefail

FLAG="$HOME/.claude/afk"
MARKS="$HOME/.claude/afk-sessions"

input=$(cat)

json_flag() {
  printf '%s' "$input" | python3 -c "
import json,sys
try:
    print('yes' if json.load(sys.stdin).get('$1') else 'no')
except Exception:
    print('no')
" 2>/dev/null
}

json_value() {
  printf '%s' "$input" | python3 -c "
import json,sys
try:
    print(json.load(sys.stdin).get('$1') or '')
except Exception:
    print('')
" 2>/dev/null
}

event=$(json_value hook_event_name)
mark="$MARKS/$(json_value session_id)"

# A typed prompt is proof Trevor is back at the keyboard. Tell the sessions that
# actually ran under AFK, once each, and only those: UserPromptSubmit stdout is
# injected into the agent's context. This runs before the flag check, since the
# whole point is to reach a session after AFK has ended.
if [ "$event" = "UserPromptSubmit" ]; then
  if [ -f "$mark" ]; then
    rm -f "$mark"
    cat <<EOF
Trevor is back: he typed this prompt himself, so AFK is over for this session.
Drop the AFK log and the "AFK: idle" marker from your responses, and put the
decisions you were making alone back to him.
EOF
  fi
  exit 0
fi

[ -f "$FLAG" ] || exit 0

expiry=$(head -n 1 "$FLAG" | tr -dc '0-9')
now=$(date +%s)
if [ -z "$expiry" ] || [ "$now" -ge "$expiry" ]; then
  rm -f "$FLAG"
  exit 0
fi

# This session is running under AFK, so it earns a return notice later. Markers
# clear themselves on that notice; sweep the ones whose sessions never came back.
mkdir -p "$MARKS" 2>/dev/null && : > "$mark"
find "$MARKS" -type f -mtime +7 -delete 2>/dev/null

# PreToolUse on AskUserQuestion: the one stall with no guesswork in it. Deny the
# call and hand the decision back to the agent.
if [ "$event" = "PreToolUse" ]; then
  cat >&2 <<EOF
Trevor is AFK and will not see this question. Decide, log, park: take the
reversible option, log it as a decision with its reason, and park the item
instead when no option is safe to take alone. Format and rules:
~/.claude/skills/afk/SKILL.md, from "Decide alone" down.
EOF
  exit 2
fi

# One nudge per genuine stop: this turn already came from a stop-hook block.
[ "$(json_flag stop_hook_active)" = "yes" ] && exit 0

# The session declares itself genuinely finished with an exact marker, so the
# hook never has to guess whether free text was a question. Stop-hook input
# carries no last message, so read it off the transcript: last main-chain
# assistant turn, text blocks only.
last_message() {
  printf '%s' "$input" | python3 -c "
import json,sys

def texts(msg):
    content = (msg or {}).get('content')
    if isinstance(content, str):
        return content
    return '\n'.join(
        b.get('text', '') for b in content or []
        if isinstance(b, dict) and b.get('type') == 'text'
    )

try:
    path = json.load(sys.stdin).get('transcript_path')
    rows = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
    for row in reversed(rows):
        if row.get('type') == 'assistant' and not row.get('isSidechain'):
            print(texts(row.get('message')))
            break
except Exception:
    pass
" 2>/dev/null
}

last_message | grep -qx 'AFK: idle' && exit 0

until=$(date -r "$expiry" '+%H:%M' 2>/dev/null || date -d "@$expiry" '+%H:%M' 2>/dev/null || echo "later")
cat >&2 <<EOF
Trevor is AFK until $until and cannot answer a question or approve anything,
including 1Password prompts. Decide, log, park: follow
~/.claude/skills/afk/SKILL.md from "Decide alone" down, and keep working.
End a response with the exact line "AFK: idle" only once every item in that log
reads done or parked; that is what lets this session stop.
EOF
exit 2

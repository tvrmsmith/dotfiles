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
[ -f "$FLAG" ] || exit 0

input=$(cat)

expiry=$(head -n 1 "$FLAG" | tr -dc '0-9')
now=$(date +%s)
if [ -z "$expiry" ] || [ "$now" -ge "$expiry" ]; then
  rm -f "$FLAG"
  exit 0
fi

json_flag() {
  printf '%s' "$input" | python3 -c "
import json,sys
try:
    print('yes' if json.load(sys.stdin).get('$1') else 'no')
except Exception:
    print('no')
" 2>/dev/null
}

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
including 1Password prompts. Read ~/.claude/skills/afk/SKILL.md and follow it:
decide it yourself, log the decision, park what needs him, and keep working.
End a response with the exact line "AFK: idle" only once the work is genuinely
finished; that is what lets this session stop.
EOF
exit 2

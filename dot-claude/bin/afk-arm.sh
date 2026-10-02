#!/usr/bin/env bash
# Arm the AFK flag: parse the return time and write its epoch to ~/.claude/afk.
#
# The afk guard hook runs this when Trevor types `/afk ...` and shows him what it
# prints, so stdout and stderr are worded for him.
#
#   afk-arm.sh "until tomorrow morning 9am"
#   afk-arm.sh 2h
#   afk-arm.sh            # no spec: 8 hours
#
# Exits 2 on a spec it cannot parse, leaving the flag untouched. Every other
# exit has written the flag.
set -euo pipefail

FLAG="$HOME/.claude/afk"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  cat <<'EOF'

Usage: afk-arm.sh [--time-only] [SPEC]

  SPEC          duration (2h, 90m, 1h30m) or clock time (4pm, 16:00, 9am),
                optionally wrapped in prose ("back at 4pm", "until 9am
                tomorrow"). Empty means 8 hours.
  --time-only   print the resolved epoch and exit; leaves the flag alone
EOF
}

args=()
TIME_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --time-only) TIME_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)         args+=("$1"); shift ;;
  esac
done
SPEC="${args[*]:-}"

command -v python3 >/dev/null || { echo "python3 not found on PATH" >&2; exit 1; }

# Prose is stripped to the one token that carries a time. A clock time already
# past today means tomorrow, which is also what "tomorrow" says explicitly, so
# the word only matters for a time still ahead today.
resolved=$(python3 - "$SPEC" <<'PY' || true
import datetime, re, sys

spec = sys.argv[1].strip().lower() if len(sys.argv) > 1 else ""
now = datetime.datetime.now()

if not spec:
    print(int((now + datetime.timedelta(hours=8)).timestamp()))
    raise SystemExit

tomorrow = bool(re.search(r"\btomorrow\b", spec))

# 1h30m / 2h / 90m / "2 hours" / "45 minutes". Both units are optional but the
# match is not: an all-optional pattern matches the empty string at position 0
# and swallows every clock time behind it.
HOURS = r"(\d+)\s*(?:h|hr|hrs|hour|hours)"
MINS = r"(\d+)\s*(?:m|min|mins|minute|minutes)"
d = re.search(rf"\b{HOURS}\s*(?:{MINS})?\b", spec) or re.search(rf"\b{MINS}\b", spec)
if d:
    hours, minutes = (d.groups() + ("0",))[:2] if d.re.groups == 2 else ("0", d.group(1))
    delta = datetime.timedelta(hours=int(hours or 0), minutes=int(minutes or 0))
    if delta:
        print(int((now + delta).timestamp()))
        raise SystemExit

# 4pm / 4:30pm / 16:00 / 9 am
t = re.search(r"\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b", spec) or \
    re.search(r"\b(\d{1,2}):(\d{2})\b()", spec)
if t:
    hour, minute, mer = int(t.group(1)), int(t.group(2) or 0), t.group(3)
    if mer == "pm" and hour != 12:
        hour += 12
    elif mer == "am" and hour == 12:
        hour = 0
    if hour > 23 or minute > 59:
        raise SystemExit(1)
    when = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
    if tomorrow or when <= now:
        when += datetime.timedelta(days=1)
    print(int(when.timestamp()))
    raise SystemExit

raise SystemExit(1)
PY
)

if [ -z "$resolved" ]; then
  echo "Cannot read a time out of \"$SPEC\", so AFK is not armed. Try /afk 2h or /afk 4pm." >&2
  exit 2
fi

until_human=$(date -r "$resolved" "+%a %-d %b %H:%M")

if [ "$TIME_ONLY" -eq 1 ]; then
  echo "$resolved $until_human"
  exit 0
fi

echo "$resolved" > "$FLAG"
echo "AFK on until ${until_human}."

#!/usr/bin/env bash
# Arm the AFK flag and wake every already-stopped Claude session, in one pass.
#
# What the /afk skill used to do by hand: parse the return time, write the epoch
# to ~/.claude/afk, then type one line into each session that has already stopped
# and so will not otherwise notice the flag.
#
#   afk-arm.sh "until tomorrow morning 9am"
#   afk-arm.sh 2h
#   afk-arm.sh            # no spec: 8 hours
#
# Exits 2 on a spec it cannot parse, leaving the flag untouched, so the caller
# can fall back to deciding the time itself and re-running with a bare `4pm`
# or `2h`. Every other exit has written the flag.
#
# Sessions Orca reports as WORKING are skipped: mid-turn, they meet the flag at
# their own next stop. A session holding a dialog gets an ESC first, and vim
# mode gets an `i` after it, since ESC lands in NORMAL there and the line would
# otherwise be typed as commands.
set -euo pipefail

FLAG="$HOME/.claude/afk"
DRY=0
SELF="${ORCA_TERMINAL_HANDLE:-}"

usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
  cat <<'EOF'

Usage: afk-arm.sh [--dry-run] [--self HANDLE] [SPEC]

  SPEC          duration (2h, 90m, 1h30m) or clock time (4pm, 16:00, 9am),
                optionally wrapped in prose ("back at 4pm", "until 9am
                tomorrow"). Empty means 8 hours.
  --dry-run     resolve the time and classify the sessions, send nothing,
                write nothing
  --time-only   print the resolved epoch and exit; touches neither the flag
                nor Orca
  --self HANDLE this session's handle, never messaged
                (default: $ORCA_TERMINAL_HANDLE)
EOF
}

args=()
TIME_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY=1; shift ;;
    --time-only) TIME_ONLY=1; DRY=1; shift ;;
    --self)    SELF="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)         args+=("$1"); shift ;;
  esac
done
SPEC="${args[*]:-}"

for c in jq python3; do
  command -v "$c" >/dev/null || { echo "$c not found on PATH" >&2; exit 1; }
done
if [ "$TIME_ONLY" -eq 0 ]; then
  command -v orca >/dev/null || { echo "orca not found on PATH" >&2; exit 1; }
fi

# ---------------------------------------------------------------- resolve time

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
  echo "afk-arm: cannot read a time out of \"$SPEC\"" >&2
  echo "afk-arm: flag untouched; re-run with a duration (2h) or a clock time (4pm)" >&2
  exit 2
fi

until_hm=$(date -r "$resolved" "+%H:%M")
until_human=$(date -r "$resolved" "+%a %-d %b %H:%M")

if [ "$TIME_ONLY" -eq 1 ]; then
  echo "$resolved $until_human"
  exit 0
fi

LINE="Trevor is AFK until ${until_hm} and cannot answer. If your last turn ended in a question or an approval request, take the reversible option and carry on under ~/.claude/skills/afk/SKILL.md. Otherwise ignore this."

if [ "$DRY" -eq 1 ]; then
  echo "flag: ${until_human} (${resolved})  [dry-run, not written]"
else
  echo "$resolved" > "$FLAG"
  echo "flag: ${until_human} (${resolved})  -> $FLAG"
fi

# ------------------------------------------------------------------- fan out

# The composer pads with U+00A0, which is not whitespace to a trim and would
# read as a draft. Fold it to a space before trimming.
tail_of() {
  orca terminal read --terminal "$1" --limit 200 --json 2>/dev/null \
    | jq -r '[ .result.terminal.tail[]
               | gsub(" "; " ")
               | gsub("^\\s+|\\s+$"; "")
               | select(length > 0) ] | join("\n")'
}

# The last `❯` line with the glyph stripped: the live composer's contents, empty
# when it is parked.
composer_of() {
  printf '%s\n' "$1" | grep '❯' | tail -1 | sed 's/^❯[[:space:]]*//' || true
}

# The four states of a stopped session, per docs/terminal-fanout.md. Only SEND
# takes the line; DIALOG takes it after an ESC.
#
# `❯` prefixes every past user message in the transcript as well as the live
# composer, so only the *last* one says anything about a draft. The render can
# also collapse to a single status line on a narrow pane, which is why "no ❯
# found" is not by itself a reason to skip.
classify() {
  local t="$1"
  case "$t" in
    *"Enter to select"*|*"esc to cancel"*|*"Do you want to"*) echo DIALOG; return ;;
  esac
  if printf '%s\n' "$t" | grep -q '❯'; then
    if [ -z "$(composer_of "$t")" ]; then echo SEND; else echo DRAFT; fi
    return
  fi
  if printf '%s' "$t" | grep -qE '(INSERT|NORMAL|VISUAL|bypass permission|shift\+tab)'; then echo SEND; return; fi
  echo UNKNOWN
}

# ESC leaves a vim-mode composer in NORMAL, where the line would be typed as
# commands. `i` returns to INSERT and ctrl-U clears whatever the dialog left.
restore_insert() {
  local h="$1" t
  t=$(tail_of "$h")
  case "$t" in
    *"-- NORMAL --"*|*"-- VISUAL --"*)
      orca terminal send --terminal "$h" --text 'i' >/dev/null 2>&1
      sleep 1
      orca terminal send --terminal "$h" --text $'\025' >/dev/null 2>&1
      sleep 1 ;;
  esac
}

sent=0; skipped=0; failed=0
left=""
while IFS=$'\t' read -r handle bucket title; do
  [ -n "$handle" ] || continue
  if [ "$bucket" = "WORKING" ]; then
    printf 'skip    %s  %s (working)\n' "$handle" "$title"
    skipped=$((skipped + 1)); continue
  fi

  state=$(classify "$(tail_of "$handle")")
  case "$state" in
    DRAFT)
      printf 'skip    %s  %s (unsent draft in composer)\n' "$handle" "$title"
      skipped=$((skipped + 1)); continue ;;
    UNKNOWN)
      printf 'skip    %s  %s (no Claude composer found)\n' "$handle" "$title"
      skipped=$((skipped + 1)); continue ;;
    DIALOG)
      if [ "$DRY" -eq 0 ]; then
        orca terminal send --terminal "$handle" --text $'\033' >/dev/null 2>&1
        sleep 1
        restore_insert "$handle"
      fi ;;
  esac

  if [ "$DRY" -eq 1 ]; then
    printf 'would  %s  %s (%s)\n' "$handle" "$title" "$state"
    continue
  fi

  # Text and Enter as two calls: the combined form has been seen to drop.
  orca terminal send --terminal "$handle" --text "$LINE" >/dev/null 2>&1
  sleep 1
  orca terminal send --terminal "$handle" --enter >/dev/null 2>&1
  sleep 2

  # An empty composer is the only proof Enter landed. Finding the line anywhere
  # in the tail is not: the composer is *in* the tail, so a half-typed line the
  # Enter never submitted matches too, and the send reports success while the
  # session sits there holding it. Retry the Enter once, then say so.
  after=$(tail_of "$handle")
  left=$(composer_of "$after")
  if [ -n "$left" ]; then
    orca terminal send --terminal "$handle" --enter >/dev/null 2>&1
    sleep 2
    after=$(tail_of "$handle")
    left=$(composer_of "$after")
  fi

  if [ -n "$left" ]; then
    printf 'FAILED  %s  %s (composer still holds %q)\n' "$handle" "$title" "${left:0:40}"
    failed=$((failed + 1))
  elif printf '%s' "$after" | grep -q 'Trevor is AFK until' \
       || printf '%s' "$after" | grep -qE '(esc to interrupt|✻|✳|◐|◑)'; then
    # Empty composer plus either the line in the transcript or a turn now
    # running. A busy session scrolls the line away inside a second, so the
    # spinner stands in for it.
    printf 'sent    %s  %s\n' "$handle" "$title"
    sent=$((sent + 1))
  else
    printf 'FAILED  %s  %s (line never appeared)\n' "$handle" "$title"
    failed=$((failed + 1))
  fi
done < <("$(dirname "$0")/orca-sessions.sh" ${SELF:+--self "$SELF"} \
         | jq -r '[.handle, .bucket, (.title | .[0:40])] | @tsv')

printf 'sessions: %d sent, %d skipped, %d failed\n' "$sent" "$skipped" "$failed"
[ "$failed" -eq 0 ]

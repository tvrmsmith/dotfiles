#!/bin/bash
# load-gate.sh — Claude Code PreToolUse (Bash) hook.
#
# Many agents share this machine, and a test suite started while it is short of
# memory or CPU runs slower, times out, and slows every other session down with
# it. Before a test-runner command, this waits while either signal is low,
# polling every LOAD_GATE_INTERVAL seconds:
#
#   memory  `memory_pressure` free percentage below LOAD_GATE_MIN_FREE_MEM
#   CPU     idle percentage from `top` below LOAD_GATE_MIN_IDLE_CPU
#
# The load average is deliberately not a signal. macOS counts threads blocked on
# I/O in it, so under swap it read 134 on 14 cores while the CPU sat 37% idle,
# and a gate keyed on it held every test run all day.
#
# The wait is capped at LOAD_GATE_MAX_WAIT seconds, after which the command runs
# anyway: a caller's own timeout keeps counting while the hook holds, so an
# unbounded wait turns a slow run into a timed-out one. The hook's timeout in
# settings.json has to stay above the cap, or Claude Code kills it mid-wait.
#
# The hook never denies and never allows. It only delays, so the normal
# permission flow still decides whether the command runs. A signal it cannot
# read counts as healthy, so a missing tool never holds anything.
#
# no-mistakes runs its unit test commands in the daemon, not through an agent,
# so this does not gate the pipeline's test step.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

CMD=$(jq -r '.tool_input.command // empty')
[ -n "$CMD" ] || exit 0

# Anchored to a command position (start, or after ; & | ( ) and past any leading
# VAR=value assignments, so that echoing, grepping, or documenting a runner is
# not mistaken for running it.
POSITION='(^|[;&|(])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
PREFIX='((npx|bunx|pnpm exec|yarn|uv run|bundle exec|python3? -m)[[:space:]]+)?'
RUNNER='(dotnet test|go test|cargo (test|nextest)|(npm|pnpm|yarn|bun)( run)? test(:[^[:space:]]*)?|vitest|jest|pytest|bats|rspec|playwright test|make test|mix test)'
printf '%s' "$CMD" | grep -Eq "${POSITION}${PREFIX}${RUNNER}([[:space:]]|$)" || exit 0

MIN_FREE_MEM=${LOAD_GATE_MIN_FREE_MEM:-20}
MIN_IDLE_CPU=${LOAD_GATE_MIN_IDLE_CPU:-10}
MAX_WAIT=${LOAD_GATE_MAX_WAIT:-900}
INTERVAL=${LOAD_GATE_INTERVAL:-30}

# "System-wide memory free percentage: 46%" -> 46
free_mem() {
  memory_pressure 2>/dev/null | awk -F': ' '/free percentage/ { sub(/%/, "", $2); print $2 }'
}

# The second sample of `top`, since the first averages since boot.
# "CPU usage: 38.47% user, 24.34% sys, 37.17% idle" -> 37.17
idle_cpu() {
  top -l 2 -n 0 -s 1 2>/dev/null | awk '/CPU usage/ { v = $7 } END { sub(/%/, "", v); print v }'
}

below() { [ -n "$1" ] && awk -v v="$1" -v m="$2" 'BEGIN { exit !(v < m) }'; }

# Sets STATE to a reading of both signals, and succeeds when either is low.
busy() {
  local mem cpu
  mem=$(free_mem || true)
  cpu=$(idle_cpu || true)
  STATE="memory ${mem:-?}% free, CPU ${cpu:-?}% idle"
  below "$mem" "$MIN_FREE_MEM" || below "$cpu" "$MIN_IDLE_CPU"
}

busy || exit 0
START_STATE=$STATE

WAITED=0
FREED=0
while [ "$WAITED" -lt "$MAX_WAIT" ]; do
  sleep "$INTERVAL"
  WAITED=$((WAITED + INTERVAL))
  if ! busy; then
    FREED=1
    break
  fi
done

if [ "$FREED" = 0 ]; then
  MSG="load-gate: machine stayed busy for ${WAITED}s (was $START_STATE, now $STATE); running the tests anyway, so expect them to be slow."
else
  MSG="load-gate: held the tests ${WAITED}s until the machine freed up (was $START_STATE, now $STATE)."
fi
jq -n --arg m "$MSG" '{systemMessage: $m}'

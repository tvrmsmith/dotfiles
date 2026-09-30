#!/bin/bash
# load-gate.sh — Claude Code PreToolUse (Bash) hook.
#
# Many agents share this machine, and a test suite started while the 1-minute
# load average is already past the core count runs slower, times out, and slows
# every other session down with it. Before a test-runner command, this waits
# until load drops to the core count, polling every LOAD_GATE_INTERVAL seconds.
#
# The wait is capped at LOAD_GATE_MAX_WAIT seconds, after which the command runs
# anyway: a caller's own timeout keeps counting while the hook holds, so an
# unbounded wait turns a slow run into a timed-out one. The hook's timeout in
# settings.json has to stay above the cap, or Claude Code kills it mid-wait.
#
# The hook never denies and never allows. It only delays, so the normal
# permission flow still decides whether the command runs.
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

cores() { sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null; }

# The 1-minute load average. macOS prints "{ 56.18 40.14 38.97 }".
load1() {
  local raw
  if raw=$(sysctl -n vm.loadavg 2>/dev/null); then
    printf '%s\n' "$raw" | tr -d '{}' | awk '{print $1}'
  else
    awk '{print $1}' /proc/loadavg
  fi
}

over() { awk -v l="$1" -v c="$2" 'BEGIN { exit !(l > c) }'; }

LIMIT=$(cores) || exit 0
[ -n "$LIMIT" ] || exit 0
MAX_WAIT=${LOAD_GATE_MAX_WAIT:-900}
INTERVAL=${LOAD_GATE_INTERVAL:-30}

LOAD=$(load1) || exit 0
over "$LOAD" "$LIMIT" || exit 0
START_LOAD=$LOAD

WAITED=0
while over "$LOAD" "$LIMIT" && [ "$WAITED" -lt "$MAX_WAIT" ]; do
  sleep "$INTERVAL"
  WAITED=$((WAITED + INTERVAL))
  LOAD=$(load1) || break
done

if over "$LOAD" "$LIMIT"; then
  MSG="load-gate: load stayed above $LIMIT cores for ${WAITED}s (was $START_LOAD, now $LOAD); running the tests anyway, so expect them to be slow."
else
  MSG="load-gate: held the tests ${WAITED}s until load fell from $START_LOAD to $LOAD on $LIMIT cores."
fi
jq -n --arg m "$MSG" '{systemMessage: $m}'

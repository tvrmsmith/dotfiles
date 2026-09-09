#!/usr/bin/env bats
# Time resolution only. --time-only touches neither the flag nor Orca, so these
# stay hermetic; the fan-out is exercised with `afk-arm.sh --dry-run`.

ARM="${BATS_TEST_DIRNAME}/../dot-claude/bin/afk-arm.sh"

# Resolved epoch as local HH:MM.
at() {
  local epoch
  epoch=$("$ARM" --time-only "$1" | cut -d' ' -f1)
  date -r "$epoch" "+%H:%M"
}

# Asserts a duration, tolerating the second that can elapse mid-test.
lasts() {
  local epoch mins
  epoch=$("$ARM" --time-only "$1" | cut -d' ' -f1)
  mins=$(( (epoch - $(date +%s)) / 60 ))
  [ "$mins" -eq "$2" ] || [ "$mins" -eq $(( $2 - 1 )) ]
}

@test "no argument means eight hours" {
  lasts '' 480
}

@test "reads a bare duration" {
  lasts '2h' 120
  lasts '90m' 90
  lasts '1h30m' 90
}

@test "reads a spelled-out duration" {
  lasts '2 hours' 120
  lasts '45 minutes' 45
}

@test "reads a clock time out of prose" {
  [ "$(at '4pm')" = "16:00" ]
  [ "$(at 'back at 4pm')" = "16:00" ]
  [ "$(at 'until tomorrow morning 9am')" = "09:00" ]
  [ "$(at '4:30pm')" = "16:30" ]
  [ "$(at '16:00')" = "16:00" ]
}

@test "midnight and noon do not swap" {
  [ "$(at '12am')" = "00:00" ]
  [ "$(at '12pm')" = "12:00" ]
}

@test "a clock time already past today lands tomorrow" {
  local now target epoch
  now=$(date +%s)
  # An hour behind the current one is always in the past today.
  target=$(date -r $(( now - 3600 )) "+%H:%M")
  epoch=$("$ARM" --time-only "$target" | cut -d' ' -f1)
  [ "$epoch" -gt "$now" ]
  [ "$(date -r "$epoch" '+%H:%M')" = "$target" ]
}

@test "a spec with no time in it exits 2 and writes nothing" {
  run "$ARM" --time-only "banana"
  [ "$status" -eq 2 ]
}

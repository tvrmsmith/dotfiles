#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

GREET="$BATS_TEST_DIRNAME/../greet.sh"

@test "greets the named person on stdout and exits 0" {
  run --separate-stderr "$GREET" world
  [ "$status" -eq 0 ]
  [ "$output" = "hello, world" ]
  [ -z "$stderr" ]
}

@test "prints usage to stderr and exits 2 with no argument" {
  run --separate-stderr "$GREET"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == usage:* ]]
}

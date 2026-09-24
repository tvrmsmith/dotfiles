#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

GREET="$BATS_TEST_DIRNAME/../greet.sh"

@test "greets the given name and exits 0" {
  run --separate-stderr "$GREET" Trevor
  [ "$status" -eq 0 ]
  [ "$output" = "hello, Trevor" ]
  [ -z "$stderr" ]
}

@test "prints usage to stderr and exits 2 with no argument" {
  run --separate-stderr "$GREET"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ "$stderr" = "usage: greet.sh <name>" ]
}

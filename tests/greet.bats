#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
load helpers/assert

GREET="${BATS_TEST_DIRNAME}/../greet.sh"

@test "greets the named person on stdout and exits 0" {
  run --separate-stderr "$GREET" Ada
  equals "$status" 0
  equals "$output" "hello, Ada"
  is_empty "$stderr"
}

@test "without a name prints usage to stderr and exits 2" {
  run --separate-stderr "$GREET"
  equals "$status" 2
  is_empty "$output"
  contains "$stderr" "usage:"
}

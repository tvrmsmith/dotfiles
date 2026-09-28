load helpers/assert
bats_require_minimum_version 1.5.0

GREET="${BATS_TEST_DIRNAME}/../greet-dotfiles-3jc.sh"

@test "greets the named person on stdout and exits 0" {
  run --separate-stderr "$GREET" Trevor
  equals "$status" 0
  equals "$output" "hello, Trevor"
  is_empty "$stderr"
}

@test "with no argument, prints usage to stderr and exits 2" {
  run --separate-stderr "$GREET"
  equals "$status" 2
  is_empty "$output"
  contains "$stderr" "usage:"
}

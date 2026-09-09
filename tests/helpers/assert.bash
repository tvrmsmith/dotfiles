# Assertion helpers for bats.
#
# bats 1.14 grades a test on the exit status of the LAST command in its body, and
# neither `set -e` in the body nor in setup() changes that. So a bare `[[ ... ]]`
# anywhere but the final line can never fail its test, and reads as passing
# forever. Every assertion goes through a helper here, each of which `exit 1`s on
# failure, which does fail the test wherever it sits.

# $1 haystack, $2 needle.
contains() {
  case "$1" in
    *"$2"*) return 0 ;;
  esac
  printf 'expected to contain: %s\n                got: %s\n' "$2" "$1" >&2
  exit 1
}

lacks() {
  case "$1" in
    *"$2"*)
      printf 'expected to omit: %s\n             got: %s\n' "$2" "$1" >&2
      exit 1
      ;;
  esac
}

is_empty() {
  [ -z "$1" ] && return 0
  printf 'expected empty, got: %s\n' "$1" >&2
  exit 1
}

# $1 actual, $2 expected.
equals() {
  [ "$1" = "$2" ] && return 0
  printf 'expected: %s\n     got: %s\n' "$2" "$1" >&2
  exit 1
}

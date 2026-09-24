#!/usr/bin/env bash
# Prints a greeting for the name given as the first argument.
set -euo pipefail

main() {
  if [ $# -lt 1 ]; then
    echo "usage: $(basename "$0") <name>" >&2
    exit 2
  fi

  echo "hello, $1"
}

main "$@"

#!/usr/bin/env bash
# Print a greeting for the name given as the first argument.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: greet.sh <name>" >&2
  exit 2
fi

echo "hello, $1"

#!/usr/bin/env bash
# greet.sh <name>: print a greeting for <name>.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: greet.sh <name>" >&2
  exit 2
fi

echo "hello, $1"

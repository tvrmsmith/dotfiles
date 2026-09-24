#!/bin/bash
# Prints a greeting for the name given as the only argument.

if [[ $# -lt 1 ]]; then
  echo "usage: greet.sh <name>" >&2
  exit 2
fi

echo "hello, $1"

# slice-pipeline

Takes a ready ticket to a verified commit. An Archon workflow plus the script it
shells out to, self-contained so it runs against any repo, not just this one.

```
bin/slice-wave                     every non-trivial rule, driven by bats
workflows/implement-slice/         the workflow and its offline fixtures
tests/                             both suites, their helpers, and the runner
```

## Run it

```sh
archon workflow run implement-slice \
  --input bead=<id> \
  --input beads_dir="$(git rev-parse --show-toplevel)/.beads"
```

Both inputs are required and the engine rejects the run without them. Read the
authored outcome (`verified`), not the run status: `verify` exits 0 on every
verdict so the run completes and keeps its artifacts either way.

## Test it

```sh
NO_MISTAKES_COVERAGE_DIR=$(mktemp -d) tests/local-test.sh
```

Runs both bats suites under a line-coverage probe, replays the workflow
fixtures through `archon workflow test`, and fails if any function in
`bin/slice-wave` went unentered. Needs `bats`, `archon`, `bun`, and `jq`.

## Why the tests are split in two

`slice-wave.bats` runs the script with the workflow absent, and `archon workflow
test` stubs the node bodies away and checks the DAG with the script absent. Both
stay green while the two halves drift apart. `implement-slice-wiring.bats`
closes that gap: it reads the command line the workflow actually declares, runs
it the way the engine does, and holds the real output to the declared
`output_format`.

## Install

`../install.sh` links `bin/slice-wave` onto `PATH` and registers
`workflows/implement-slice` in Archon's global scope, which is what makes the
workflow resolve from repos other than this one. A new script here is not on
`PATH` until that runs from the main checkout.

The tree is stow-ignored and holds its own test helpers, so
`git subtree split --prefix=slice-pipeline` lifts it into its own repo intact.

# slice-pipeline

Takes a ready ticket to an open pull request that no-mistakes has driven green.
An Archon workflow plus the script it shells out to, self-contained so it runs
against any repo, not just this one.

```
bin/slice-wave                     every non-trivial rule, driven by bats
workflows/implement-slice/         the workflow and its offline fixtures
tests/                             the suites, their helpers, and the runner
```

## Run it

```sh
archon workflow run implement-slice \
  --input bead=<id> \
  --input beads_dir="$(git rev-parse --show-toplevel)/.beads"
```

Both inputs are required and the engine rejects the run without them. Read the
authored outcome (`delivered`), not the run status: `verify` and `validate` both
exit 0 on every verdict so the run completes and keeps its artifacts either way.
`delivered` is only true once a commit landed, no-mistakes drove it to a
checks-passed or passed pull request, and the findings record posted on that PR.

The target repo needs a GitHub remote you can push to and an initialized
no-mistakes; `claim` checks both before it touches the branch or the tracker,
and fails the run with what to fix if either is missing.

Review `waivers` before merging a slice. The build runs unattended, so it records
personal coding-standards lint waivers without asking, and this lists each one
spent on the slice's commits, read from the waiver log rather than the model's
report. A non-empty `waivers_error` means the log was unreadable and the list is
not to be trusted.

## Test it

```sh
NO_MISTAKES_COVERAGE_DIR=$(mktemp -d) tests/local-test.sh
```

Runs the bats suites under a line-coverage probe, replays the workflow
fixtures through `archon workflow test`, and fails if any function in
`bin/slice-wave` went unentered. Needs `bats`, `archon`, `bun`, and `jq`.

```sh
SLICE_E2E=1 SLICE_E2E_REPO=owner/name bats tests/e2e.bats
```

Runs the real pipeline once, against a real GitHub repository named by
`SLICE_E2E_REPO` that you can push to and open pull requests on: claim's own
forge and no-mistakes preflight checks refuse anything else, including a
scratch repo with no remote. It clones that repository to scratch, runs
`no-mistakes init` there, then drives one small bead through the real
pipeline - claim, a real model build, verify, a real no-mistakes validate
drive, and release - and checks the branch, the committed code, the bead and
the pull request's findings record comment directly. Teardown closes the pull
request and deletes its remote branch. It spends model tokens, pushes a
branch and opens a pull request on a real repository, and can go red on a bad
model run, so it skips unless `SLICE_E2E=1`, and skips with a clear message
when `SLICE_E2E_REPO` is unset.
`SLICE_E2E_CLONE_URL` optionally overrides the URL it clones from, for a
machine whose git credential for gh's default URL belongs to a different
account than gh's; gh still reaches the repository through `SLICE_E2E_REPO`.
`SLICE_E2E_KEEP=1` keeps the scratch repo and Archon's worktree for
inspection, and leaves the pull request and its branch open too.
An Archon run from source needs `CLAUDE_BIN_PATH` pointing at an up-to-date
`claude`, or its prompt nodes fail on the older copy bundled in its SDK.

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

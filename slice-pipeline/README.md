# slice-pipeline

Takes a ready ticket to a merged pull request that no-mistakes drove green,
then closes the ticket and removes the run's worktree. An Archon workflow plus
the script it shells out to, self-contained so it runs against any repo, not
just this one.

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
authored outcome (`merged`), not the run status: `verify`, `validate` and
`merge` all exit 0 on every verdict so the run completes and keeps its
artifacts either way. `merged` is only true once a commit landed, no-mistakes
drove it to a checks-passed or passed pull request, the findings record posted
on that PR, and the forge reports the PR merged. Only then does `close` close
the bead and remove the worktree. An unmerged run hands the bead back open and
unclaimed, and leaves any pull request open.

The target repo needs a GitHub remote gh can open pull requests on, a git
credential that can push to origin, and an initialized no-mistakes. `claim`
checks all three (the push through `git push --dry-run`) before it touches the
branch or the tracker, and fails the run with what to fix if any is missing.

`merge` squashes by default. A repository that uses a merge queue is named in
the machine-local `${XDG_CONFIG_HOME:-~/.config}/slice-pipeline/repos.json`,
read at run time and keyed by `owner/name`:

```json
{"owner/name": {"merge_queue": true}}
```

A queued repository is enqueued with no strategy flag. `merge` fails if the
queue drops the pull request after holding it, once a re-read
`SLICE_WAVE_MERGE_DROP_GRACE_SECONDS` (default 5) later still finds it open and
unqueued. At the deadline it disables auto-merge and dequeues the pull request,
so the queue cannot land it after the bead goes back to the frontier. If the file exists but
jq cannot read it, `merge` refuses to merge rather than guess squash.

Review `verify`'s `waivers` after a slice merges. The build runs unattended, so
it records personal coding-standards lint waivers without asking, and this
lists each one spent on the slice's commits, read from the waiver log rather
than the model's report. A non-empty `waivers_error` means the log was
unreadable and the list is not to be trusted.

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
pipeline (claim, a real model build, verify, a real no-mistakes validate
drive, merge and close) and checks the branch, the committed code, the closed
bead, the merged pull request, its findings record comment and the removed
worktree directly. A green run merges a small script and its test into the
repository, named after the bead so reruns do not collide. Teardown closes any
pull request still open on the slice branch, deletes that branch, and releases
Archon's registration of the scratch clone as the target repository's
codebase. It spends model tokens and merges into a real repository, and can go
red on a bad model run, so it skips unless `SLICE_E2E=1`, and skips with a
clear message when `SLICE_E2E_REPO` is unset.
`SLICE_E2E_CLONE_URL` optionally overrides the URL it clones from, for a
machine whose git credential for gh's default URL belongs to a different
account than gh's; gh still reaches the repository through `SLICE_E2E_REPO`.
`SLICE_E2E_KEEP=1` keeps the scratch repo, and Archon's worktree when close
left it, for inspection, leaves the pull request's branch in place too, and
leaves Archon's registration of the scratch clone in place.
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

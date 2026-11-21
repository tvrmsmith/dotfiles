# slice-pipeline

Takes a ready ticket to a pull request its repository's validator delivered,
waits for an engineer to approve it in a review tab, merges it, then closes the ticket
and removes the run's worktree. An Archon workflow plus
the script it shells out to, self-contained so it runs against any repo, not
just this one.

```
bin/slice-wave                     every non-trivial rule, driven by bats
bin/wave-status                    where a wave chain stands, read from Archon
workflows/implement-slice/         one slice: the workflow and its offline fixtures
workflows/implement-in-waves/      a parent's children, wave by wave, each behind a seam gate
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
artifacts either way. `merged` is only true once a commit landed, the validator
delivered a pull request, the findings record posted
on that PR, an engineer approved it in review, and the forge reports the PR
merged. Only then does `close` close the bead and remove the worktree. An
unmerged run hands the bead back open and unclaimed, and leaves any pull
request open. A failed review is the exception, below.

Every delivered slice ends at a review tab. `review` opens an Orca tab in the
target's main checkout, titled `review <bead> #<pr>` and running
`tuicr pr owner/name#<pr>` beside `slice-wave review-watch`, then pauses the
run at `review-gate`, a native Archon attention wait. The watcher answers the
gate from tuicr. An empty `:send` on the pull request's current head answers
`approved` with that head, and only then does `merge` run, pinned by
`--match-head-commit` to the head that was reviewed. A send with comments
answers `comments`, and the run pauses again in a new round; fixing the
comments is the next slice's job. Quitting tuicr without a send is not
approval either. The watcher counts every send tuicr records after the tab
opens, including one in the fresh session file tuicr starts when it reloads
onto a new head. Sends a session held before the tab opened never count.

The watcher resumes the run itself, detached, so closing the tab after a send
cannot stop the merge. It survives the tab closing, logs to
`~/.local/state/slice-pipeline/review-<run-id>.log`, and exits once it
approves, the pull request closes, or the run stops. Answering the gate by
hand works too: `archon workflow answer <run-id> --occurrence <pauseId>
--choose approved` (the pauseId is in `archon workflow get <run-id> --json`),
then `archon workflow resume <run-id>`. An approval with no text approves the
head the gate's question showed. After 20 rounds the run fails with the bead
still claimed and the pull request open, and `archon workflow resume
<run-id>` picks the review back up. A pull request closed or merged outside
the pipeline fails the review the same way.

Review needs Orca running and a tuicr built from Trevor's fork branch
`groupdiff`, which keeps a released session after tuicr quits and reports its
`head_sha` in `review list`. `SLICE_WAVE_REVIEW_POLL_SECONDS` (default 15) sets
how often the watcher reads tuicr, the forge and the run.

The target repo needs a GitHub remote gh can open pull requests on, a git
credential that can push to origin, and its validator. `claim` checks all
three (the push through `git push --dry-run`) before it touches the branch or
the tracker, and fails the run with what to fix if any is missing.

How each target is validated and merged lives in the machine-local
`${XDG_CONFIG_HOME:-~/.config}/slice-pipeline/repos.json`, read at run time
and keyed by `owner/name` as `gh repo view` names it. A repository absent
from the file, or the file itself absent, gets the defaults: no-mistakes and
squash.

```json
{"owner/name": {"validator": "imr-ship", "merge_queue": true}}
```

`validator` is `no-mistakes` (the default) or `imr-ship`. A no-mistakes
target needs an initialized no-mistakes, and `validate` drives it under
`--yes` to a checks-passed or passed pull request. An imr-ship target needs
`imr` on PATH, and `validate` runs `imr pr ship --autofix-review`, which
stops before ci, so review and merge stay the pipeline's. It delivers once
that exits 0 with a pull request open. Any other exit is a halt that needs a
person: the run reports it undelivered and hands the bead back, the reason
names the line the ship stopped on, and the ship waits in the run's worktree
for `imr pr ship --resume --autofix-review`. Never start a fresh
`imr pr ship` over it. A validator the file names but slice-wave has no
adapter for, or a file jq cannot read, fails `claim` and `validate` rather
than guess.

`merge` squashes unless `merge_queue` is true. A queued repository is
enqueued with no strategy flag. `merge` fails if the
queue drops the pull request after holding it, once a re-read
`SLICE_WAVE_MERGE_DROP_GRACE_SECONDS` (default 5) later still finds it open and
unqueued. At the deadline it disables auto-merge and dequeues the pull request,
so the queue cannot land it after the bead goes back to the frontier. If the
file exists but jq cannot read it, `merge` refuses to merge rather than guess
squash.

Review `verify`'s `waivers` after a slice merges. The build runs unattended, so
it records personal coding-standards lint waivers without asking, and this
lists each one spent on the slice's commits, read from the waiver log rather
than the model's report. A non-empty `waivers_error` means the log was
unreadable and the list is not to be trusted.

## Implement a parent bead in waves

```sh
cd <target repo checkout>
archon workflow run implement-in-waves --detach \
  --input parent=<id> \
  --input beads_dir=<tracker>/.beads
```

Start it from the target repository's checkout, since every slice cuts its
worktree from that repository's `origin/<base>`. `beads_dir` names the
tracker, which can live in another repository. The wave lists the parent's
direct children that `bd ready --unassigned` reports. It never takes a
grandchild, a claimed bead, or a child with an open child of its own, which
bd would refuse to close after its slice merged. `--input max_slices=N` caps a wave at N
slices and leaves the rest for later waves. The default of 0 means no cap.

Before any slice starts, the wave pauses on a seam gate. An agent reads each
candidate bead and the code on `origin/<base>`, and proposes the modules
each slice touches, the interfaces where slices meet, and the pairs that
would edit the same code. Each seam cites the bead text or code it comes
from. A slice that neither constrains gets no invented boundary, because
approved seams become precedent for later waves. The gate's text says what
each bead is, where each seam came from, and what Approve will do. Choose
`approve`, or `revise` with comments in the text. A revise can also say
`drop <id>` to hold a bead for the next wave, or `not this epic <id>` to take
it out of the parent. On approval, `apply-seams` appends each dispatched
bead's seams to its notes and clears each not-this-epic bead's parent. It
then fixes the wave and the chain's tried list. A dropped bead is in
neither, so the next wave offers it again. That needs a next wave, though,
and a wave that dispatches nothing ends the chain. A wave with no candidates
skips the gate.

Then the wave runs one implement-slice for each approved child, all at once,
each in its own worktree.

A wave ends once every one of its slices has finished, and a slice waiting in
review counts as unfinished. So the next wave starts only when every slice of
this wave has merged or handed its bead back. If the wave dispatched anything,
its `next` node starts the following wave detached, passing on the list of
beads the chain has tried. A later wave never retries a bead an earlier wave
released, so a slice that failed is not rebuilt in a loop. The chain ends on
a wave that finds nothing new. That wave's `close-parent` node closes the
parent once every direct child is closed. Otherwise it leaves the parent open
and names the children still open, such as a released or kept-claimed bead.
It never forces the close. One failed slice leaves its siblings and the
chain running. Its bead lands where implement-slice puts it: a build or
validate failure hands it back, and a failed review keeps it claimed.

```sh
wave-status <any wave's run id, or a unique prefix> [--json]
```

This prints one row per bead across the whole chain: the wave, the bead, the
slice run holding it, that run's state, and its worktree. The last line says
whether the chain is still going, and if so, which run to cancel to stop it.
An ended chain's last line also says whether the parent closed, or which
children kept it open.
The rows cover the beads the seam gate approved, not every candidate. A
wave still at its gate lists none, and a bead taken out of the parent never
appears. `bd list` may still draw that bead under the parent, since it keeps
its hierarchical id, but its parent is empty.
A slice's state is one of `running`, `awaiting review`, `merged`,
`released`, `kept claimed`, `not claimed` (its claim failed), `starting` or
`not started` (the seam gate approved the bead but no run exists yet, or
never will), or `cancelled` or `failed`, with `, still claimed` when the run had
claimed the bead. `wave-status` stores nothing. It reads the most recent 1000
runs from `archon workflow runs` and follows each wave's `previous` input back
and forward. `--json` prints the same rows for a script to read.

To stop, cancel the live wave: `archon workflow cancel <run>`. Archon cancels
its running slices with it. There is no soft stop. A cancelled slice never
reaches `release`, so `wave-status` shows its bead as `cancelled, still
claimed`. Hand it back with `BEADS_DIR=<tracker>/.beads bd unclaim <id>`.

The bead claim protects a bead only once a slice has claimed it. bd lets the
same user claim a bead twice. Two dispatches of one parent started within
seconds of each other, before the first wave's slices claim their beads, can
build the same bead twice. Wait for the first wave's slices to show `running`
before dispatching that parent again.

### Front a run

The workflows never notify anyone. Whoever fronts a run drives its gates
through Archon's CLI: a person in a terminal, a chat session, or a bot all
work the same way.

```sh
archon workflow wait <run> --json      # blocks until a gate opens or the run ends
archon workflow answer <run> --occurrence <id> --choose revise --text 'drop <id>' --json
archon workflow resume <run> --detach
```

`wait` returns the open gate's `occurrence`, its message and its options.
Put the message to whoever decides, answer with their choice, resume, then
wait again. Without `--json`, `answer` resumes the run itself, in your
shell, and holds it until the run pauses or ends. `answer` has no
`--detach`, so a front that must stay free records the answer with
`--json` and continues the run with `resume --detach`. `wait` returns at
once when a gate is already open, so a front that slept or lost its session
reruns it on waking.

Each wave starts the next one detached, so waiting on the first wave sees
only that wave. Follow the chain with `wave-status <run>`: its last line
names the live wave to wait on next. `archon workflow attention` lists
every open gate across runs, which covers a wave and its slices' review
gates together.

On an `imr-ship` target, a slice whose ship halted hands its bead back with
the halted ship still in its worktree. The chain will not dispatch that bead
again, but a fresh dispatch of the same parent will, and a fresh ship over a
halted one is what the ship rules forbid. Resume the halted ship first.

## Test it

```sh
NO_MISTAKES_COVERAGE_DIR=$(mktemp -d) tests/local-test.sh
```

Runs the bats suites under a line-coverage probe, the bun suite for
implement-in-waves' scripts and `wave-status` (bd and archon stubbed on PATH, and
`wave-status` read against run listings recorded from a live wave), replays
both workflows' fixtures through `archon workflow test`, and fails if any
function in `bin/slice-wave` went unentered. Needs `bats`, `archon`, `bun`, and `jq`.

```sh
SLICE_E2E=1 SLICE_E2E_REPO=owner/name bats tests/e2e.bats
```

Runs the real pipeline once, against a sandbox GitHub repository named by
`SLICE_E2E_REPO` that you can push to and open pull requests on. It has to be a
real forge repository, since claim's own forge and no-mistakes preflight
checks refuse a scratch repo with no remote. It also has to be disposable,
because a green run merges into it. The suite refuses any target unless it
can confirm a committed `.slice-e2e-sandbox` file at the root of its default
branch. It checks the clone it pushes to and, through gh, the repository it
merges on, before it pushes or opens anything, and a failed gh check refuses
too, quoting gh's own error. Make a sandbox once with
`gh repo create --private` and commit that file to its default branch.

The suite clones the sandbox to scratch, runs
`no-mistakes init` there, then drives one small bead through the real
pipeline (claim, a real model build, verify, a real no-mistakes validate
drive, review, merge and close) and checks the branch, the committed code, the
closed bead, the merged pull request, its findings record comment and the
removed worktree directly. The run waits in review like any other, so the
suite plays the engineer. It waits for the review tab in Orca and for tuicr to
persist the session, sends an empty `:send`, follows the run the watcher
resumes until it ends, and then checks the tab's title and that the session
released with no comments. `SLICE_E2E_MERGE_TIMEOUT_SECONDS` (default 10800)
bounds that last wait.
`SLICE_E2E_REVIEW_TIMEOUT_SECONDS` (default 16200) bounds that wait, and a
send that never happens kills the run. It needs Orca and tuicr as review
does. A green run merges a small script and its test into the
sandbox's default branch, named after the bead so reruns do not collide.
Teardown closes any pull request still open on the slice branch, deletes that
branch, closes the review tab, and releases Archon's registration of the
scratch clone as the target repository's codebase. It spends model tokens and
merges into the sandbox, and can go
red on a bad model run, so it skips unless `SLICE_E2E=1`, and skips with a
clear message when `SLICE_E2E_REPO` is unset.
`SLICE_E2E_CLONE_URL` optionally overrides the URL it clones from, for a
machine whose git credential for gh's default URL belongs to a different
account than gh's; gh still reaches the repository through `SLICE_E2E_REPO`.
`SLICE_E2E_KEEP=1` keeps the scratch repo, and Archon's worktree when close
left it, for inspection, leaves the pull request's branch and the review tab
in place too, and leaves Archon's registration of the scratch clone in place.
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

`../install.sh` links `bin/slice-wave` and `bin/wave-status` onto `PATH` and
registers both workflows in Archon's global scope, which is what makes them
resolve from repos other than this one. A new script here is not on
`PATH` until that runs from the main checkout.

The tree is stow-ignored and holds its own test helpers, so
`git subtree split --prefix=slice-pipeline` lifts it into its own repo intact.

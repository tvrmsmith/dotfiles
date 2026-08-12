---
name: split-loop-branch
description: >-
  Use when a long-running agent loop has piled many commits onto one branch and
  they need to ship as separate pull requests — "split this branch into PRs",
  "one PR per bead", "break up the gnhf branch", "these 30 commits need separate
  PRs". Maps commits to beads, finds file-overlap clusters, cherry-picks each
  group onto current main in a scratch worktree, and triages conflicts before
  handing each branch to the normal gates. Not for splitting a single large
  commit into smaller ones (use `git rebase -i`), and not for shipping one
  finished branch (use /ship-pr).
---

# Split a loop branch into per-bead PRs

A `gnhf`/`imr loop` run leaves one branch holding dozens of commits, each
closing its own bead. Reviewers need them separated. The split itself is
mechanical; the judgement is in **clusters**, **staleness**, and merge order.

## 1. Inventory

```bash
git fetch origin main -q
git log --oneline origin/main..HEAD | cat          # commits + their bead IDs
for c in $(git rev-list --reverse origin/main..HEAD); do
  echo "=== $c"; git show --name-only --format= $c
done
```

Loop commits name their bead in the subject, so the mapping is usually already
one commit per bead. Watch for the exceptions: commits closing **two** beads,
and commits that are loop plumbing (a lint fix that unblocked a commit, a
worktree repair) rather than a bead.

## 2. Map the clusters

A **cluster** is a set of commits touching the same file. Clusters decide
whether commits can be independent PRs:

- **Merging serially** (one PR open at a time) — clusters need no special
  handling. Each later branch rebases onto the already-merged main and the
  conflict is gone. Grouping cluster members into one PR is then a *review-size*
  choice, not a necessity.
- **Merging concurrently** — cluster members must either stack or be grouped
  into a single PR.

Surface this to the human before building anything, along with each cluster's
combined diff size. A 4-bead 850-line cluster is a worse review than four
130-line PRs.

## 3. Build the branches

Cherry-pick each group onto current `origin/main` in a scratch worktree, so the
loop branch stays untouched as the backup:

```bash
git worktree add --detach ../_pr-build origin/main
```

Then per group: `git checkout -B <branch> origin/main && git cherry-pick <shas>`.

**Run multi-commit groups one at a time.** A `while read` loop over
`git cherry-pick a b` leaves `.git/sequencer` behind and the *next* iteration's
`checkout -B` fails silently, reporting a conflict with an empty conflicted-file
list. An empty conflict list means a broken loop, not a real conflict — re-run
that group on its own before believing it.

Order the groups foundational-first — kernel, then shared platform, then
products, then docs. Every merge shifts main, and low-level changes touch the
most files, so landing them early costs the fewest rebases.

**Check commit count before comparing files.** A group whose cherry-pick never
landed leaves the branch head equal to its base, and an empty branch passes every
file-subset check vacuously — the empty set is a subset of anything, so the audit
below reports it clean. Count first:

```bash
git rev-list --count $(git merge-base origin/main "$b").."$b"
```

Zero means the group was never built, not that it had nothing to do. Its commits
then survive only on the loop branch, so they die with it.

Zero usually means the group needed a **predecessor group** that its base lacked:
the commit applied on the loop branch because an earlier group had already landed
the code it edits. Rebuild it on that predecessor's branch instead of on
`origin/main`, and let the stack rebase as each one merges. The tell is a diff3
conflict whose `HEAD` side is empty while the `|||||||` base section is full — the
incoming commit is editing code the base does not have.

**Check commit count before comparing files.** A group whose cherry-pick never
landed leaves the branch head equal to its base, and an empty branch passes every
file-subset check vacuously — the empty set is a subset of anything, so the audit
below reports it clean. Count first:

```bash
git rev-list --count $(git merge-base origin/main "$b").."$b"
```

Zero means the group was never built, not that it had nothing to do. Its commits
then survive only on the loop branch, so they die with it.

Zero usually means the group needed a **predecessor group** that its base lacked:
the commit applied on the loop branch because an earlier group had already landed
the code it edits. Rebuild it on that predecessor's branch instead of on
`origin/main`, and let the stack rebase as each one merges. The tell is a diff3
conflict whose `HEAD` side is empty while the `|||||||` base section is full — the
incoming commit is editing code the base does not have.

Audit before handing anything off: each branch's changed files must be a subset
of its source commits' files. Diff against `git merge-base origin/main <branch>`,
**not** `origin/main` — main moves during the session, and diffing against the
moved ref reports main's own new files on every branch at once. That
all-branches-at-once shape is the signature of a moved base, not of a real
problem.

## 4. Triage the conflicts

Sort conflicted branches into two kinds, because only one is work:

- **Intra-cluster** — conflicts only against a sibling branch's commit. Free:
  resolves when the predecessor merges. Leave it.
- **Against new main** — real. Main has moved since the loop branch forked,
  possibly by hundreds of commits.

Resolve the real ones in parallel lanes (one worktree per concurrent agent,
grouped by domain so each agent holds coherent context).

**Check staleness first.** Loop agents work from bead descriptions that may
already have been overtaken, and main may have fixed the same defect
independently — several beads in a typical run turn out stale on inspection.
Confirm the defect still exists on main before resolving; if it doesn't, drop
the branch and report the superseding commit as evidence. Reconcile the two
sides; taking either side wholesale silently discards one of them.

**The characteristic failure is a rigorous check against a partial view.** Not
sloppy work — correct procedure, run against the default rendering of something
with more in it. A bead read as description plus close reason, its comments never
scrolled. A tree checked out and inspected without asking what it already
contains. An instructions file re-read at the path it was written to, after it
moved. Each time the check is sound and the answer is wrong, and the report is
confident because the procedure was followed. Absence is the claim that needs
provenance: presence carries its own evidence and absence never does. Before
concluding a thing is missing — a source for a number, a defect, a rule — name
which rendering of the artifact you looked at, and whether it is the whole of it.

It binds mutation testing hardest, because **an unapplied mutant and a surviving
mutant produce identical output** — a green run and a live claim that the test
does not pin the thing. Confirm the mutant is in the file (`git diff --stat`)
before believing any survival, and make the edit itself assert its anchor — an
insert located by line number fails loudly on an off-by-one rather than landing
somewhere harmless.

The same identical-output trap catches verification of a **declaration** fix. Code
that compiles through a transitive reference compiles just as well after a direct
one is added, so a green build is a no-harm check and not evidence the fix did
anything. The discriminator is removing the path the code was hiding behind: cut
the transitive edge and the build must still succeed after the fix and must break
before it. Quote both outputs. Enumerate the paths before designing that cut: a
second edge through an intermediate project leaves the mutant cutting one of two,
so the arm that discriminates is the one cutting **every** path at once, and an
error naming the intermediate is not an error about the thing under test. Where the
answer comes back "not load-bearing", the fix is still worth keeping as declaration
hygiene — but say so, rather than letting a PR body claim it repaired a fragile
build.

**Mutating an uncommitted file: snapshot to `/tmp` and restore by `diff`.**
`git checkout -- <file>` is the right revert for a committed file and silently
wrong for one the branch does not yet carry — it discards the round's work along
with the mutant, and the green re-run afterwards looks identical either way.

**When a sweep's result surprises you in either direction, test the matcher on a
known-good case before believing it.** An over-matching absence check manufactures
findings exactly as readily as an under-matching one hides them, and both report
with the same confidence. Path separators are the classic: a pattern written with
forward slashes misses every csproj that spells the same reference with
backslashes, and every one of those becomes a finding. The tell is quantity — a
count larger than the defect's plausible population is evidence about the matcher,
not about the tree.

This binds the checks you *write*, not only the ones you run. A grep prescribed
as a pass condition is an absence claim delegated to someone else, so grep the
artifact for the exact string before making it the gate — a case-sensitive
`grep -F 'missing tenant'` against a file that says `Missing tenant` reports
failure on a success, and the report is honest.

**Give a prohibition a number to report.** "Do not consolidate these assertions"
is the instruction a fixer follows right up to the point where it decides it is
being helpful. "State the count of literal header strings in the assertions
before and after; they must be equal" is the same rule as a checkable criterion,
and it is much harder to drift past. This applies wherever the thing you are
protecting is something a competent fixer would otherwise think it should tidy.

The same form is what makes a criterion survive the gap between where a rule is
read and where it is applied: a skill is read when you sit down, an instruction is
read at the moment of the decision, and guidance that has to be remembered loses
that transfer every time. "Report the file list this grep returns; it must be
exactly `<file>`" fails visibly at the point of use when the grep is wrong, where
"confirm the grep matches the artifact" does not. So **write each criterion by
running it**, not by reasoning about it, and paste the output you got as the
expected value.

**A rule inferred from one file is tested on one file.** Two different rules agree
wherever your sample happens to satisfy both, so the narrower one reads as general
until it meets the case that separates them. Where a fixer must place something,
prefer a criterion that points at an existing peer — "put it in the same `<Folder>`
as an existing test-project entry" needs no scheme inferred, and lands right in
files organized by area and by kind alike.

**A criterion copied from another branch's instruction brings its justification,
not its validity.** It was true where it was written and it arrives reading as
settled, so it escapes the scrutiny a new criterion gets — a live rule correctly
applied to the wrong tree, which no amount of retired-rule discipline catches
because nothing about it was ever retired. Re-derive a transplanted check against
the tree it will run on: the classic is a pre-change baseline that discriminated on
a branch where the symbol already existed, and degenerates to a compile error on
one that introduces it.

**A retired rule survives in whatever you already wrote from it.** Correcting the
rule does not correct its answers, and those answers now read as independent
conclusions rather than as consequences of something discarded. After overturning
a criterion, re-derive every instruction that was written under it — the tell is a
line arguing for a placement or a value with no reason attached, because the reason
was the retired rule. Deleting the reason is what does the damage, so mark it dead
in place rather than striking it — its outputs stay greppable by their
justification.

The same fork opens inside a single item. **A count stated in prose and the list
given underneath it are two separate claims, and nothing in the format makes them
agree** — "all four do this today" above a table of three, and the fixture matches
the table, because the enumeration is what gets built. So write the count *from*
the list rather than beside it, or drop the count and let the list carry it. When
they disagree, the list is what shipped and the prose is what you believed.

The sharpest instance is the artifact's own **reporting checklist**, which is a
second copy of every rule the body states. Amending the body silently forks them,
and the checklist is the copy that wins: the body is read when the fixer sits down,
the checklist at the moment of the decision, so a retired criterion left in the
checklist is not a stale line, it is the live instruction. The fixer produces what
the checklist asks for and reports it as complete, and the correction never landed
at all. So after retiring a criterion, **grep the whole artifact for it** rather
than editing the section that argued for it — and expect a full read by two people
to miss the fork, because both copies are individually plausible and only their
disagreement is the defect.

**Ask whether the defect was present then, not whether it is present now.**
Checking out a tree and finding the defect gone answers a different question
than the branch asks, because the tree you happened to pick may already contain
the repair. Before reporting a defect absent from main, name the commit that
repaired it and run `git merge-base --is-ancestor <repair> <tree>` against the
tree you tested. Base drift corrupts causes, not only counts: two people
independently checking "does this file compile on main" can both answer yes,
both be right about their tree, and both be wrong about the branch.

**Ancestry answers "is it coming"; path history answers "was it here".** They
differ exactly on deletions, and a deletion is invisible to the first. A name
present in some branch and absent from main has two shapes — not merged yet, or
merged then removed — and the ref topology alone does not separate them, so the
reachability check returns a confident answer to a question you were not asking.
`git log --oneline main -- <path>` is what distinguishes them, and the removing
commit is the one worth naming: a conclusion built on the wrong shape here
predicts the return of something that was deliberately taken out.

**A local fix on main is not a supersession when the branch's subject is
consolidation.** The near-miss: main independently rediscovers the same defect
and fixes it *file-locally* — its own private constants, its own helper — which
reads at the conflict as "already fixed, drop the branch". For a branch whose
point is that the thing is declared once repo-wide, main's local fix is one more
duplicate to remove, and dropping the branch leaves the repo with two competing
copies and no single declaration. Test the branch's subject, not the defect's
presence.

A conflicting file may be *gone* rather than changed — renamed or rearchitected
out from under the commit. `git ls-tree -r --name-only origin/main | grep <name>`
and `git log --follow` find where it went, and whether the defect survived the
move.

**A reviewer's proposed assertion can be your own error handed back to you.** A
finding that says "pin this output" usually quotes a value from somewhere upstream
in the conversation, and if that value came from your own isolated run of a helper
rather than from the command, accepting the finding writes the error into a test —
where it outranks the docs, because a test looks verified. Run the command and read
its real output before pinning anything a review quotes. The general fix is to
assert the invariant rather than the text: the absent service and the exit code,
not the sentence, since a fixture legitimately prints differently from the real
manifest.

**A sentence is not covered by the tests that cover the function it describes.**
A rule's code can be exhaustively pinned — every case, every product, green twice
over — while the prose stating that rule in a doc comment and two CLAUDE.md files
says the opposite, because no test ever read it. Run the documented rule against
the same case table the code was tested against; the tell is a doc that contradicts
itself a few lines on, having stated the rule abstractly and then given a correct
worked example.

**Resolution is not runnability, and a dry run tests only the first.**
`[DRY-RUN] billing-migrate: make billing-migrate` shows the command that would be
issued, not that the target exists — so a documented example can be verified,
printed, and dead. Any example naming a build target earns a
`grep -nE '^<target>:' Makefile` hit, including examples the current round did not
write. The same split shows up one level higher: measuring a helper in isolation
and reporting its answer as the command's behaviour, when the command feeds it a
larger input — a graph pulls in dependents before the filter runs, and the real
output is a passing-looking plan rather than the no-op the helper predicts.

**Verify each resolution against the diff yourself.** A stale drop is the right
call and still ships a broken PR, because the commit message keeps promising the
fix that was dropped. Compare each branch's actual diff to what its message
claims; reword to conventional format describing what the branch *does*, naming
the superseding PR for whatever was dropped. The tell is a shape mismatch — a
"fixed a production bug" message over a zero-deletion diff.

**Prefer a same-tree delta to an absolute count** in any message or doc the split
produces. During a split, "main" names several trees at once — the loop branch's
fork point, each lane's base, the main checkout's unfetched ref, and whatever
`origin/main` became during the session — so an absolute ("686 tests") is a true
count of one of them and wrong for the rest, while reproducing perfectly on
re-measurement. A delta measured by changing one file in one tree ("47 tests fail
without this") cannot drift with the base. Better still for a consolidation, a
**zero-assertion**: "no occurrence of the old spelling remains" holds on any tree
and cannot be satisfied by a stale number. Asking for "8 of 8 migrated" and
getting it is a pass on an incomplete job the moment main adds a ninth. Where
only an absolute will do, pin it to a sha, and re-fetch before believing any ref
called main. Two independent enumerations agreeing on a *total* is not agreement:
two lists of 13 can differ by two members, one of them a name that does not exist.
Reconcile membership, and build any fixture from the source of truth rather than
from the other list.

**Regenerate committed generated artifacts after the rebase, not before.** A
gate round that regenerates a checked-in artifact does so against the branch's
old merge-base. If the rebase then pulls in any change to that artifact's
sources, the committed copy is stale again — and every content check that passed
during the round still passes, because it was run against the right sources at
the wrong time.

Frontend branches need `node_modules` before their tests run — see the worktree
section of the repo `CLAUDE.md`.

## 5. Hand off

Each branch is now an ordinary finished branch. The gates already have skills:

- `no-mistakes` — local review + tests + lint per branch, before anything is pushed.
- `tuicr` — human review.
- `/ship-pr` (`imr pr ship`) — rebase, verify, push, open, merge queue.

`no-mistakes` resolves a run from the **current** repo and branch — neither
`status` nor `respond` takes a run id. Fire each from the worktree holding that
run's branch, and read stdout: `respond` prints `error: no active run to respond
to` and still **exits 0**, so a mis-fired answer looks like a delivered one and
the run sits parked. To see another lane's state without leaving your worktree,
query `~/.no-mistakes/state.sqlite` (`runs`, `step_results`, `step_rounds`)
directly — and state the filter alongside any "no run" conclusion, because a query
narrowed to `running` hides the state that matters most: `completed` with an empty
`last_pushed_sha` is not an inert row, it means the gate holds a head your local
branch may have diverged from.

**A run that never gates never delivers your instructions.** The instruction file
reaches a fixer only through `respond` at a gate, so a review returning nothing but
`info` findings passes the whole run with the material undelivered — and the run
reports `passed`, which reads as "the work was done". Check what the run actually
changed against what you asked for. Recovering custody (`sync --recover`) and
applying the items by hand as a follow-up commit is the normal path, not an
escalation; revalidate afterwards and expect the head to be unchanged by the
pipeline.

**Recover custody before aborting a run, not after — the fix commits may exist
nowhere else.** Every fix round's commit lands in the gate's own repo, and the
lane's worktree keeps the original cherry-pick. A run parked at a gate loses nothing
because both copies persist; the abort is the event that strands the gate's copy,
and `axi run` validates **local HEAD**, so the rerun silently starts from the
pre-fix commit. Every finding the rounds fixed comes back, and the rerun goes green
on the unfixed code — a fresh pass on the original tree is indistinguishable from a
pass on the fixed one. Before any abort-and-rerun, ask where the fix commits live
and settle it with `git cat-file -e <fix-sha>` in the worktree rather than by
reasoning. If it fails, `sync --recover` first: after the rerun there is a pending
run with no push binding and sync refuses.

**Do not price the cost of an abort from the step table.** `document: no edits,
lint: 0` describes the steps of the *current* round and is silent about commits
produced by earlier ones — so it answers "was this round's work cheap" when the
question is "what exists only in the gate". The table returns a confident number to
a question it cannot see, which reads as an assessment rather than as a category
error. Price it from the commit graph.

**An assessment expires at the state change it was made under.** "Nothing is lost
while it sits parked" can be exactly right and become wrong the instant you act on
it, because the action is what invalidates it. Carrying a conclusion across the
event it was conditioned on is the same staleness fault as reusing a base revision
after main moves — and it is harder to catch, because a conclusion carries no
revision to check.

**Never abort a run to resolve uncertainty about a flag.** Aborting is a certain,
immediate loss of a validated in-flight run and every fix round in it. The harm it
forestalls — a push that should have skipped — is bounded and reversible when `pr`
and `ci` are skipped alongside: a branch ref on origin with no PR opened, undone by
one `git push --delete`, seen by nobody and merging nowhere. Watch the run, and
clean up after it if the flag did not hold. Certain loss against bounded reversible
harm is not a close call, and the run itself produces the direct observation every
inference has been standing in for. Make this standing policy rather than a
judgement each lane re-makes under time pressure, because deciding it fresh while a
step is executing is how the expensive option gets chosen.

**A control that only exists on the failure path is absent when things go well.**
Planning to withhold an approval is not a hold on the run if a clean result advances
itself: the decision point you meant to stand at is offered only when there is
something to decide, so the success path walks straight past it and the run is three
steps further on before anyone notices the control never engaged. Nobody watches a
step that went well. Before relying on a gate, establish that it is reached
unconditionally — and where it is not, put the control somewhere the happy path must
also pass through.

**A gated branch lives in two places at once.** The pipeline rebases onto current
main and holds the result in its own bare repo, while the lane's worktree stays at
the pre-rebase head. Reading a file from the worktree therefore answers about a
different tree than the gate is reviewing — same path, same command, different
blob, and nothing in either read announces the difference. Read from the gate repo
(`git show <gate-head>:<path>`), and name the **blob sha** of what you read rather
than the path, so two people comparing notes can tell whether they read the same
bytes. Derive that sha with `git rev-parse <rev>:<path>`, or
`git ls-tree -r <rev> --format='%(objectname) %(path)'` when naming several files
at once — a git object id hashes
`blob <len>\0` before the contents, so it never equals `shasum` of the file, and a
halt built on the raw hash fires on a correct tree.

**A criterion is a claim, so verify it in both directions.** Running a check
against known-bad input proves only that it can fire; a gate that always fires is
indistinguishable from that, and it spends its credibility on correct work.
Run every prohibition and every halt against a tree you know is right and confirm
it passes, and against input you know should fail it and confirm it fires. A value
transcribed from a real run proves the criterion executes, never that it
discriminates — the worst case is a guard returning its pass value because the
thing it names does not exist yet, which cannot fail at all and still reads as
protection. This binds hardest on criteria written as mitigations for a real hazard,
because the hazard is what carries them through review.

**A temporarily unfalsifiable criterion is worse than a permanently wrong one.**
A check that can never fire gets found out, because it never fires. A check that
is inert only until some other branch merges — a grep for a symbol that does not
exist yet, a guard on a file not written yet — banks credibility across exactly
the window in which it protects nothing, then starts discriminating silently in a
report nobody re-reads. Afterwards it looks like it always worked. This is why
"what input makes this fail?" is a question asked when the criterion is written,
not when it is reviewed: the window closes on its own, and closing it destroys the
evidence that it was ever open.

**Assume every run will try to push, including one started with `--skip=push`.**
A gated branch is not a shipped branch, but the pipeline does not know that — it
runs to `push` and then `pr` on its own, and a human review step planned for
later is invisible to it. If
nothing may reach the remote before review, the backstop has to be something the
pipeline cannot route around: no usable push credential for the duration. Check
the remote after each run rather than trusting the run's own account of what it
did — and check it with something that cannot report success on a failure:

```
out=$(git ls-remote origin '<branch-prefix>/*'); rc=$?
[ $rc -eq 0 ] || echo "UNVERIFIED: ls-remote exit $rc"
echo "refs=$(printf '%s' "$out" | grep -c .)"
```

**A counting pipeline turns an unreachable remote into a clean pass.** The
obvious spelling of that check, `git ls-remote … | wc -l`, prints 0 when the
remote answers with nothing *and* when authentication never happened at all —
`wc` counts the empty output of a command that exited 128 and reports the same
number either way. So the guard against the one outcome the split exists to
prevent is the guard most likely to be inert, and it fails silently in the
reassuring direction, for as long as the credential stays broken. Read the exit
status, and report the command beside the count: a number with no provenance
survives being relayed upward in a way a command does not. The lesson generalises
past this one check — **a count is never evidence on its own**, because every
counting construct in the shell absorbs the failure of what it counts. Beware too
of the second credential that looks like a fallback: a token-authenticated path is
independent of an SSH agent only until both come from the same vault, and then
"try the other one" is one dependency checked twice.

**A repeated scalar flag keeps only its last value, silently.** `--skip=push
--skip=pr --skip=ci` and `--skip=push,pr,ci` read as the same instruction and are
not: where the flag is declared `--skip string` rather than as a repeatable slice,
the first spelling discards everything but `ci`, and the run pushes and opens a PR.
There is no warning, no rejection, and no trace in the run's own records — the
mistake is visible only in the launch command, and only if you notice the form.
Check the declaration in `--help` before trusting a repeated flag, and prefer the
single-value spelling the declaration asks for. The failure has a nasty second
property: because the *last* value is honoured, the flag appears to work, so the
run's behaviour looks like a flag that "sometimes holds" rather than a
misspelling — which is exactly the wrong diagnosis to reach, because it condemns a
reliable mechanism and leaves the real defect free to recur.

**Launch-time configuration is not in the tool's records — but it is in the
transcripts.** Nothing about the flags survives in the run row or the step logs,
and a step that will be skipped reads `pending` beforehand, the same value as one
that will execute. That much invites the conclusion that the configuration is
unknowable, and it is wrong. Agent sessions write their tool calls to disk with
timestamps, so the launch command is on record wherever the launching session's
transcript lives, and a run's `created_at` correlates to it within seconds. Two
runs of the same pipeline with different flag spellings and opposite outcomes then
form a discriminating pair, which is a far stronger instrument than any reading of
the status rows. Reach for the transcript before concluding that a configuration
cannot be recovered — the general form of this is the direct-record rule below,
and this is its highest-value instance, because the alternative is releasing a
parked run into a sequence whose end you cannot see. Where a resume verb
(`respond`) has no flags of its own, it inherits the launch configuration; recover
the launch command rather than reasoning about the inheritance.

**When a run's own rows cannot answer, query the population of prior runs.** The
state a run does not persist is often still legible in aggregate: other runs
already did the thing you are about to do, and their terminal rows record how it
came out. Skip state living only in daemon memory makes `push: pending`
uninformative for *this* run — but a query for every run that used the resume verb
and reached push returns five that traversed one to five resume rounds and still
recorded `push: skipped, 0ms`, which settles the inheritance question empirically
and costs nothing. The single most valuable row is the one whose launch command
you can independently confirm, because it pins both ends of the inference.

Two conditions make the population admissible, and neither is optional. **The
query must be able to return the other answer** — here, runs that reached
`completed 21009ms` and `failed 8665ms` at push, proving `skipped` is written on
purpose rather than being what the field says when nothing happened. **Each
counter-example must be explained, not outvoted**: a run that pushed after eight
resume rounds is either a launch without the flag or a refutation, and the
difference is the whole finding. A majority is not a mechanism.

The move generalises past skip state to anything the tool declines to record —
which agent ran, which config was layered, whether an optional step was armed. Ask
who else has already been in this state, before concluding the state is
unobservable.

**Prefer a positive discriminator over an absence check, and validate its
control.** "The remote has no such ref" is an absence, and every mechanism that
produces it — an empty listing, a dead credential, a typo in the pattern — reads
the same. A field known to populate on the event you fear is stronger: if
`last_pushed_sha` fills in on every real push, then empty across your branches is
evidence rather than silence, and a broken credential cannot forge it. Prove the
control first by counting the rows where the field *is* populated; a column that
is empty everywhere discriminates nothing. It answers a narrower question than the
remote does — no push *by this pipeline* — so say which question it answered.

**A check is vulnerable exactly when its expected value is what breakage
produces.** This is the narrow form of the pipe trap and the one worth carrying:
piping is only the mechanism. A counting guard that must print 0 is satisfied by
never running, because empty input counts to zero — so `git diff … | wc -l` against
a nonexistent revision returns the passing value. Guards expecting a non-zero count
or a named line are not immune by being better written, they are immune by what
they expect: breakage prints nothing, and nothing is not two named lines. So audit
every "must be 0" in a set specifically, and let the others stand.

**Pair every zero-expecting check with a control that must come back non-zero.**
Three independent mechanisms produce the same reassuring zero — an unreachable
remote, a genuinely empty result, and a pattern that matches nothing by
construction — and swapping in a better tool addresses only the first. A control
query against something that certainly exists (`refs/heads/main` returning 1) rules
out the third; reading the exit status rules out the first; what remains is the
answer. Run the control in the same invocation style as the check, or it is
attesting to a path the check does not take.

**The remedy is a sibling, not a rewrite.** Sometimes the vulnerable check can be
repaired in place — capture the status, drop the pipe — but often the command is
correct as far as it goes and no rewrite reaches what ails it: an emptiness check
prints empty for a mistyped path, a wrong working directory, or a dropped `--`.
What distinguishes "unchanged" from "never ran" is a second file put through the
*same command* that must come back non-empty. Where a guard is a hand-run grep,
write the pattern down: an unwritten pattern inherits the wrong-idiom failure on
top of the empty-result one, and neither leaves a trace.

**Name the base revision in every diff criterion.** `git diff --numstat -- <file>`
with no revision compares the working tree against HEAD, so once the round commits
its work — which it does before reporting — the diff is empty whether the round
touched the file or not. The constraint is not merely weak; it *cannot fail*, and
it fails open in the pass direction, so it reads as a clean guard forever. Write
`git diff --numstat <round-base> -- <file>` instead, and note that this defect
survives specifically by being **copied forward**: the sibling constraints written
fresh each round all carried a base commit, and only the one propagated verbatim
from round one kept the revisionless form. Audit copied lines harder than new ones
— a criterion earns its correctness once, at the moment it is written, and
inherits nothing afterwards.

**A real signal for the wrong half is worse than no signal.** When one commit does
two things and the suite can only observe one of them, the run comes back green on
genuine evidence — and that evidence gets read as covering both. This is worse than
an unfalsifiable check, because the green is real, so nobody looks past it. Split
the diff by observability before choosing the verification: for the half the tests
cannot reach, say so explicitly and fall back to a criterion that can fail, a
committed-source count expecting 1 rather than a suite expecting green. Source-text
counts are legitimate as *instruction* criteria even where they would be a poor
committed test.

**A mutant needs a baseline, a landing proof, and a unique anchor.** Three ways a
mutation run reports a conclusion it did not establish. Without a **baseline run**
the red proves the suite is red, not that the mutant caused it — take the green
count before mutating and again after restoring, and quote both. Without a
**landing proof** an unapplied mutant and a surviving one produce identical output,
so read `git diff --stat` before reading the test result. And a mutant applied by
string replacement needs its **anchor asserted unique** before the edit: a pattern
matching two sites edits both and moves two variables at once, and a pattern
matching none is a silent no-op that reads as a survived mutant. Move one variable
per mutant — when killing a raiser, leave the sibling event in place — so the red
names a cause rather than a neighbourhood. Restore from a snapshot and confirm with
`git diff --quiet`; a mutant left in the tree contaminates every later run.

**Mutate both legs before believing either.** "This test cannot die" and "this test
dies only for the right reason" are different claims, and a single mutant answers
only one. Kill the *mechanism* the test names and kill the *guard* the commit adds,
in separate runs: the pair tells you which assertions pin the behaviour under
change and which pin an invariant that holds regardless. Expect the answer to
reassign credit — a test dismissed as unable to fail often dies cleanly under the
other leg, which means it was pinning something real that nobody had named.

**A sweep across revisions needs a known-positive row inside it.** Iterating a
property over a series of commits produces a table that reads as history, and a
table of zeros reads as "absent throughout" when it may mean the command never ran
once. Include a revision where you have already confirmed the property by eye, and
check that row first: if the known-positive comes back zero, the sweep is broken,
not the history. The mechanism is usually quoting — in zsh, `"$c:path"` after an
unbraced parameter is eaten as a `:x` modifier and yields a mangled revision
argument, so write `"${c}:path"` — but the control catches every mechanism,
including the ones you have not met.

**A control taken from before the file existed is not a control.** The natural way
to prove a count of 1 is meaningful is to run it at the base and watch it print 0 —
but on a branch that *creates* the file, `git show <base>:<path>` fails, writes
nothing, the pipe swallows the status, and the counter faithfully reports 0. That
zero measures a missing file, and a path typo produces the identical one. Check
existence separately and unpiped (`git cat-file -e <rev>:<path>`), record an absent
file as ABSENT rather than as a zero, and take the varying control from *inside* the
branch instead — successive commits where the count moves 0, 2, 3 prove the
instrument tracks the thing it claims to.

Note where that defect was written: in the same edit as a paragraph documenting a
neighbouring trap. **Finding a trap does not inoculate the sentence next to it** —
attention spent naming one failure mode is not attention spent auditing the lines
around it, so re-read the whole file after any edit that adds a warning to it.

**A control that bypasses the broken machinery proves nothing.** Running the check
inside a loop and the control as a hand-written line beside it is the commonest way
to certify a sweep that never ran: the hardcoded pair returns the right answer while
every generated pair silently errors. Put the control *through the same loop*, over
the same variable, with the same quoting — and give it a **non-empty expected
answer**, a row you already know produces several hits. Those two properties are
separate and you need both: a self-intersection control run inside the loop still
passes on a broken matcher, and a known-collision control run beside the loop
validates a code path the sweep never takes. The catching control is the one that
runs where the real rows run and must come back with something in it. In zsh specifically, an unquoted `$var`
holding newline-separated items does **not** word-split, so `for x in $list` iterates
once over the whole blob, every ref is invalid, and with stderr suppressed each
iteration returns "no match" — a full sweep reporting zero findings. Build the list
as an array (`arr=(${(f)"$(...)"})`) and print its length against an expected count
before trusting a single row of the output.

**Set-intersection tools fail open.** `comm -12` requires both inputs sorted in the
collation it expects, and mis-collated input returns a **false empty** — which is
the hoped-for answer when you are checking for overlap, so it reads as good news.
Use an order-independent matcher (`grep -F -x -f`) instead. That replacement has its
own version of the same failure: `grep -f <missing-file>` matches nothing and prints
nothing, so an upstream command that died and never wrote its input renders exactly
like a clean non-overlap, with the only tell on stderr beside a row that reads as a
pass. Check each input file exists and is non-empty before intersecting, and treat
any nonzero exit upstream as fatal to the row rather than as an empty row.

**Self-intersection is a weak control; intersect a pair with a known collision.**
Feeding a list against itself passes even when the matcher is subtly broken, because
identical input survives most defects. The control that discriminates is two
*different* branches you already know overlap, returning the files you already know
about. Prove the instrument finds real overlaps, not just its own reflection.

**A screen may trade precision for recall — but say which way it errs, in its own
output.** A detector that surfaces the one file that matters inside a short list of
false positives is doing its job, because a human dismisses the extras in one grep.
The same detector read as a verdict manufactures confident wrong explanations. State
the limitation beside the result rather than in the message that delivers it once:
a regex that intersects declaration names across a whole file is scope-blind, so
five legal overrides of one name in five nested classes read as a collision. The
danger is not the imprecision, it is the imprecision outliving the person who knew
about it — an unattended rerun has only the output.

**Rank a screen's limits by whether they produce noisy positives or quiet
negatives.** Both are worth stating and only one is dangerous. An imprecise matcher
hands you extras you dismiss in a grep; a narrow one hands you a clean row you act
on. A declaration-level collision screen is blind to two sides editing the same
method *body* — the ordinary merge conflict — so an inspected row with zero
candidates predicts no duplicate declaration and says nothing about rebase safety.
Name the narrow question the instrument answers, in its output, next to the rows
that look like verdicts.

**A clean row from a detector that never inspected the file type is not a clean
row.** `member-collisions=0` on a branch whose drifted files are `.tsx` and `.ts`
means the `.cs`-only detector found nothing to look at. Absence of a finding and
absence of an inspection render identically; make the screen report what it skipped.

**An aggregate cannot see a permutation, so validate a comparator on a swap.**
When two independently-built maps agree, the agreement is only as strong as the
comparator's ability to report disagreement — and the natural shortcut, comparing
the edge list or the cluster summary, is invariant under the one disagreement most
likely to matter. Swap two independent branches' file sets and the per-branch data
genuinely differs while the edge count, the edge payloads and the cluster sizes all
come back unchanged: a real disagreement rendering as clean agreement. Validate the
comparator against injected mutations before believing its verdict — an extra file,
a removed file, and a swap between two branches — and compare the **per-branch**
sets, not only what is derived from them.

**`git merge-tree --write-tree` is the conflict oracle; file-overlap matching is a
heuristic that stands in for it.** Overlap analysis — same file, hunk line ranges,
colliding declarations — is the right tool for the questions git cannot answer, such
as whether two textually disjoint edits are *semantically* in tension. It is the
wrong tool for "will this conflict", because git already answers that exactly,
read-only, without touching a worktree or a ref: exit 0 for clean, exit 1 plus the
conflicted paths otherwise. Run it over every branch against the target before
trusting any heuristic ranking of them.

The heuristic's failure is not noise, it is aim. On one branch the sweep flagged the
OpenAPI spec, inspected it, and correctly found no collision — while the actual
conflict sat in two contract-test files the sweep never flagged at all. A clean
report on the watched file says nothing about the unwatched ones, and the sweep had
no way to know which set it was in. Across thirty branches the oracle returned five
conflicts and twenty-five clean in a single pass; the sweep had spent hours ranking
the twenty-five.

Two limits keep it honest. It answers "conflicts with the target as it stands", so
it must be re-run after every merge, and it is silent about a branch that merges
cleanly and then fails to build. Pair it with a control — merge two branches you
believe are disjoint and confirm exit 0 — so a run that returns clean for everything
is distinguishable from one where the invocation is wrong.

**Two legs of a comparison legitimately have different bases — do not flatten them
onto one.** When a comparator asserts that both sides derive from the same base and
the assert fires, the tempting repair is to force both legs onto a single head's
base. That discards the extra commits on whichever leg has them, and on a gated
branch those commits are the entire reason the leg exists: the local worktree holds
the original cherry-pick at five files while the gate holds it rebased with four
fix rounds at fifteen. Flattening turns a loud, correct refusal into a quiet wrong
answer. Fix the comparison, not the inputs — and write the distinction into the
code as a comment, because the next person to meet the assert meets it while
annoyed.

**Assert the property, not a proxy that usually implies it.** Two repositories
fetching on their own schedules are routinely a commit or two apart, so an equality
check between their `origin/main` fires on the system operating normally. The
property that actually matters is narrower — neither side holds a commit the other
lacks in the direction that would make the data incomparable — so assert
ancestor-or-equal, in the direction that still refuses the gate being *ahead*. This
is the rare case where relaxing a guard strengthens it: a guard that fires on
non-faults gets deleted by whoever is next inconvenienced, and it gets deleted
entirely rather than narrowed. State the direction in the assert's own message, and
print both values every run so the guard's verdict is auditable without reading its
source.

**Agreement between two implementations sharing a defect is not corroboration.**
Two maps built by different agents matching byte-for-byte is strong evidence only if
the implementations differ where it counts. When both carry the same flawed
derivation — the same ancestry walk instead of a `merge-base`, the same unasserted
assumption — the match says the defect is deterministic, not that the answer is
right. Record which version of the other implementation you compared against, and
re-run once its fix lands.

**A long-running step and a stopped one look identical from outside.** Silence is
not a state, so a lane working hard on a thirty-minute round and a lane that died
present the same way — and the tempting fork, "hasn't started" versus "started and
went quiet", is a two-way reading of a three-way world that omits the common case.
No state change can resolve it, because the state not changing is what both look
like. Require a heartbeat on a clock rather than on events: run id, step, round,
and **last-activity age**, which is the one field that discriminates. A check-in
with no news is information; waiting for the next state change is not.

**"Will a future reader need this bridge" is a measurement, not a preference.**
Deciding whether to keep a rename's provenance, a deprecation note or a
compatibility alias invites two arguments that both sound reasonable — it is stale
detail, versus someone will hit the old name and be lost. Settle it by grepping the
old term across the tree, with a control grep on the new one so a zero means the
term is absent rather than the search broken. One hit, inside the very note under
discussion, and the rename is fully propagated. Check what the target document
already says before adding: the same fact may be sitting a few lines above, which
turns a borderline judgement call into plain duplication.

**The frozen intent is not the artifact that outlives the run.** When a reviewer
proves a claim in the launch intent false and offers "fix the code or amend the
claim", the second option looks unavailable because the intent is fixed at run
creation — which pushes you toward taking a code change you did not want, or toward
an abort to correct a sentence. Both are overpriced. The commit body and the PR body
are what every future reader actually sees, and those stay editable; the intent is
read by the gate and then by nobody. Take the deferral and qualify the claim
downstream. The one thing you may not do is repeat the unqualified sentence into the
PR after a reviewer has disproved it.

**A deferral is worth exactly the test that pins it.** Accepting a known defect as
documented-and-deferred converts it from a bug into a contract, and the contract is
held by whatever test asserts the current behaviour. So the moment a finding becomes
the evidence for a deferral, its own quality stops being a nit and becomes
load-bearing — and the assertion most often used to pin a no-op is an absence over
empty output, which passes just as well when the fixture stopped producing anything
at all. Re-rate the pinning test upward when the deferral is taken, not before.

**Diagnose a channel with a probe that can fail, not from traffic patterns.** A
heartbeat proves a lane's *outbound* works and says nothing about its inbound, so a
lane can report health on a ten-minute clock forever while receiving none of your
messages. Repeated heartbeats then read as a working relationship: the counter
advances, the state is coherent, and only the content — "awaiting your call" on a
call already sent six times — carries the fault. Settle it with a probe whose reply
is a specific string the lane can only produce by having read the message
(`PROBE OK <time> <sha>`), and name the negative outcome in advance: no reply by the
next heartbeat means dead. Two data points shaped like a story are not a
measurement; the probe is cheap and the misdiagnosis is not. When the verdict is
dead, say so to every other lane — a one-way lane keeps broadcasting stale state
that looks exactly like a pending decision.

**Carry the payload inside the probe.** A probe that asks only for an
acknowledgement wastes a round trip when the channel is fine, which is the common
case, so pair the probe demand with a compact restatement of every decision the lane
is waiting on. A live lane acts immediately and a dead one costs nothing extra. The
restatement has a second use: three lanes reporting "blocked on your nod" after the
nod was sent looks like a broken channel and is usually messages crossing — but
after one confirmed dead channel you no longer get to assume which, and a probe that
also unblocks is cheap enough to send on suspicion rather than on evidence.

**Resolve every ref, path and run id in a written instruction against the repo
before handing it to a lane.** These files are written once and cited for hours, and
a branch name in a header is exactly the kind of detail that gets typed from memory
and never checked, because everything around it is carefully measured. One such file
named a branch that did not exist; it was cited twice before anyone ran `git
rev-parse` on it, and it surfaced only because an unrelated idle heartbeat prompted a
re-read of the worktree list. A file that reads as authoritative and names a
nonexistent ref is worse than no file — the lane trusts it and burns a cycle
discovering the ref is gone. The check is one command and it discriminates on its
own: the real branch resolved while the fictional one returned `fatal: Needed a
single revision`.

**Before assigning a branch to a worktree, check the branch is not already checked
out in another one.** Git refuses a second worktree on the same branch, so an
assignment that reads fine as a sentence fails on contact. When the holding worktree
belongs to a lane that has gone inert, reuse that directory rather than removing it —
removal is a mutation that buys nothing, and the parked lane's process may still be
running commands from that path.

**When a lane goes quiet, read its transcript before you rehome its work.** A
subagent's session file is on disk and readable, and it answers a question the
messaging channel structurally cannot: what the lane is *doing*, as opposed to what
it last managed to tell you. Two silences that look identical from the outside are
not: one lane sat idle for eighty minutes emitting byte-identical heartbeats, and
another was three minutes into launching the next branch on its own initiative and
about to report it. Rehoming the second lane's queue on the strength of its silence
would have cancelled work already in flight and doubled up a worktree. The tail of
the file — last dozen entries, tool calls included — is enough, and the timestamp of
the last inbound message it actually received localises the fault to inbound versus
outbound without any probe at all. Run a control while you are there: the obvious
culprit for a severed inbound is context compaction, and counting compactions per
lane killed that theory immediately — the one lane whose channel still worked had
compacted fifteen times, twice as often as either dead one. A cause the healthy case
also has is not the cause.

**A dead inbound turns every "I will do X once you confirm" into work that silently
never happens.** This is the expensive half of a one-way channel, and it is invisible
because the lane's reports look diligent: it correctly identifies a defect, correctly
scopes it out of the branch in hand, correctly offers to file the ticket on your
word — and then the word never arrives, the run moves on, and the finding dies in a
message nobody actioned. Sweep a one-way lane's reports for conditional commitments
and execute them yourself rather than leaving them queued behind an acknowledgement
that cannot land. Filing the ticket takes a minute; the finding is gone otherwise.

**Verify a lane's escalated finding against source before ruling, and look for the
argument it did not make.** A lane that has already checked its own claim is usually
right, so the value of re-reading is rarely catching a lie — it is finding the
evidence that converts a judgement call into a settled one. A mapper sending an
explicit `"UNKNOWN"` to `Other` was reported as a suspected defect and rested there;
one grep for the enum's own definition turned up FHIR `administrative-gender`
attributes on the platform type establishing `unknown` and `other` as distinct codes,
which moves it from "looks wrong to me" to "contradicts the standard the codebase
already declares it follows". Same verdict, different strength — and strength is what
survives into the ticket.

**Outbound-only lanes are not dead lanes; scope the rehoming to what needs you.** A
lane that cannot hear you can still execute a queue it was given before the channel
broke, and will, correctly. Split its remaining work by whether it needs a ruling:
items already specified travel with the lane, and only the ones blocked on a decision
move. That turns "redistribute six items to the one live lane" into "move one fix
round" — worth the transcript read on its own.

**Look for a direct record before settling for a sound inference.** "Step B ran, and
A precedes B, so A succeeded" is valid and still second-best: it is one-directional,
so it yields nothing when B is absent, and it proves only that A happened, never
what A did. Ask first whether the system already writes the event down — reflogs,
step timing rows, cached refs — because a timestamped line naming the operation
survives the case where the inference collapses and carries the payload as well.
Corroborate it across independent readings that must agree (the cached ref, the
live remote, the parent of the rebased head) so a single lying source cannot carry
the claim. Then scope it in time: a leg that worked at 03:40 is evidence about
03:40, and a sibling branch untried since gets its own rows read, not this one's
carried across.

**A pinned base revision goes stale when the gate rebases — which happens only if
the run got past step 0.** Naming the base fixes the vacuous-diff defect, but the
pin is true only at the moment it is written: a run that reaches the rebase step
replays the branch onto freshly fetched main and every criterion expressed against
the old base now answers a question about a superseded history. Nothing announces
it; the file still reads precise and the commands still run. So derive the base at
the *start* of each round with `git merge-base`, captured unpiped with its own exit
check, rather than pasting a value — a pasted base is correct on exactly one side
of a rebase, and a derived one is correct on both. Report the `base=` line beside
the result so the divergence is visible instead of silently absorbed.

The precondition is the part to get right, and it is easy to overgeneralise from a
single branch: a run that **died at step 0 never rebased**, so its gate copy is
byte-identical to local and its pinned base is still good. "The gate rebases what
it holds" is false; "a run that gets past step 0 rebases" is the rule. Check which
case a branch is in before carrying a sibling's lesson onto it. And a rebase is
predictable rather than merely discoverable — intersect the branch's paths with
`git diff --name-only <old-base>..<new-main>` beforehand and an empty set tells you
the replay is clean before you spend a run finding out.

**A correction is not self-validating.** The second version of a claim is produced
by the same person under the same conditions as the first, so a retraction arriving
with confidence deserves the re-derivation the original should have had — and
re-derive it against the tree, not against the correction's own quoted evidence.
Worth the cost specifically because of what a correction usually fixes: **a right
answer resting on a wrong reason is more durable than a wrong answer**, since it
passes review on the conclusion and the reason is what gets reused afterwards. When
you replace the reason, keep the retraction visible in the file rather than quietly
swapping the text — a later fixer who greps and rediscovers the rejected candidates
needs to see they were considered, or the analysis reads as having a hole in it.

**Search for the mechanism, not the type name, and scope the search to where the
mechanism lives.** A census of "what could observe this change" done by grepping
the type name returns sites that *mention* it, which is a different set and often
disjoint from the real one — two files constructing their own options object are
mentions, not observers. Decompose the behaviour into the conditions it actually
requires, search for each separately, and note that a matcher confined to one
directory cannot see a condition that lives in another: a test project cannot show
you the column mappings in Infrastructure that decide whether the path is reachable
at all. The half you cannot search from where you are standing is the half the
census exists to find. Expect the honest answer to be zero more often than small.

**Check the instrument answers the question the criterion asks.** A guard can be
unfalsifiable not because it cannot fail but because its command cannot speak to
it — `--numstat` reports how many lines changed and never which, so a criterion
demanding "the only changed lines are inside the doc comment" cannot be evaluated
by it at all. The fixer then substitutes a command nobody specified, or reports the
number and moves on. The tell is a criterion about *which* or *where* answered by a
tool that reports *how many* — or by a tool counting the wrong unit: `grep -c`
counts matching *lines*, so three names sharing two lines report 2 against a
correct file. That variant fails in the opposite direction to everything else here,
as a **false failure** driving an unnecessary edit to a file that was already
right, which is why "does breakage produce the pass value?" does not catch it. Ask
the question both ways: what makes this print the pass value wrongly, and what
makes it print a failure wrongly.

Where the criterion is about *which*, demand the output **verbatim rather than a
count** — a file list of 22 is satisfied by twenty-two wrong paths.

A loud check can still be read quietly. `$?` after a pipeline is the status of the
**last** command in it, so a check that correctly exits non-zero prints `exit=0`
the moment someone pipes it through `tail` or `head` to tidy the output — an
`[ERROR]` line sitting directly above a zero, with the zero being the part that
gets transcribed. Capture the status of the command itself, unpiped, before
formatting anything.

**Check that a step's evidence is actually on the branch.** A gate step that
writes a new test file, runs it, and never stages it reports green on evidence
the branch does not carry. Nothing fails: the step ran the file it wrote, and the
file survives only if some later step's `git add -A` happens to sweep it in. Where
a step's report names a file it created, confirm the file is tracked in that
step's own commit rather than a downstream one.

**Reword last, after the final gate.** The split rewords loop subjects
(`gnhf 11: …`) into conventional form, and that reword is a rewrite of a commit
the gate may already hold. Submitting the reworded branch to a gate that ran on
it before is rejected non-fast-forward — against the gate's own repo, not
`origin` — because the two heads are divergent rewrites of identical content.
`sync --check` does not diagnose it; it answers `next_action: run_pipeline`,
which is the thing that fails. Recovery is reset-to-gate-head after confirming
`git patch-id --stable` pairs all match, then reword once nothing further will
run. Any branch already reworded *and* already gated is carrying this.

**Before resetting to a gate head, check what sits on top of it.** "Reset to the
gate head" is the right shape for the reword trap and the wrong instruction for any
branch carrying a commit the gate never saw — following it deletes that commit, and
nothing complains. Pair every head involved by `git patch-id --stable`; an unpaired
commit is content, not a rewrite artifact, so stop rather than resolve. A backup
ref's name tells you *when* it was made, never *where* it sits: `backup/…-pre-amend`
can be the gate head plus one commit, i.e. the forward target rather than the
fallback. `git merge-base --is-ancestor` is what answers that, and the target worth
choosing is the one that fast-forwards from the gate with every patch-id intact.

**`blocked_recover_diverged` on custody return is the normal case, not a
divergence.** The local branch still sits at the pre-rebase head while the
pipeline rebased onto current main. `--keep-local` is the flag the wording
invites and the one that destroys the work: it keeps the stale head and drops
every gate fix. Confirm nothing local is unique — `git log --left-right`, or
compare `git patch-id --stable` pairs — then tag the old head, reset to the
preserved ref, and re-run `sync --recover`.

`no-mistakes` resolves a run from the **current** repo and branch — neither
`status` nor `respond` takes a run id. Fire each from the worktree holding that
run's branch, and read stdout: `respond` prints `error: no active run to respond
to` and still **exits 0**, so a mis-fired answer looks like a delivered one and
the run sits parked. To see another lane's state without leaving your worktree,
query `~/.no-mistakes/state.sqlite` (`runs`, `step_results`, `step_rounds`)
directly.

**Answer the push gate with `--action skip`.** A gated branch is not a shipped
branch, but the pipeline does not know that — it runs to `push` and then `pr` on
its own, and a human review step you have planned for later is invisible to it.
Skip it explicitly on every run rather than trusting the run to stop after `lint`.

Two costs worth predicting out loud, since both surprise people:

- `imr verify` is transitive. A kernel-wide branch fans out to most of the repo
  and can gate slower than every other branch combined.
- The seeder smoke needs a live Aspire stack, and stacks collide across
  worktrees. Run it in one lane, serially, and only for branches touching a
  service API.

## 6. Clean up

Record the branch→bead mapping and the agreed process in a tracking bead up
front — the split outlives any one session. Remove the scratch and lane
worktrees when the last PR merges; keep the original loop branch until then.

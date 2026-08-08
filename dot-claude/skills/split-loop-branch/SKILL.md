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

A conflicting file may be *gone* rather than changed — renamed or rearchitected
out from under the commit. `git ls-tree -r --name-only origin/main | grep <name>`
and `git log --follow` find where it went, and whether the defect survived the
move.

**Verify each resolution against the diff yourself.** A stale drop is the right
call and still ships a broken PR, because the commit message keeps promising the
fix that was dropped. Compare each branch's actual diff to what its message
claims; reword to conventional format describing what the branch *does*, naming
the superseding PR for whatever was dropped. The tell is a shape mismatch — a
"fixed a production bug" message over a zero-deletion diff.

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

---
name: finish-worktree
description: Finish development on a worktree end-to-end — take committed work from validation through a merged PR, then hand the beads issue back to the user to close.
disable-model-invocation: true
---

# Finish Worktree

Orchestrate existing skills in order — delegate each stage to its owning skill
rather than re-implementing it. Stages are strictly sequential: each depends on
the prior succeeding, so on any stage failure or blocker, **STOP and report to
the user.**

## 0. Resolve context

Establish and echo one line of resolved config so a misparse is caught early:

```
Worktree: <path> · Branch: <branch> · Beads: <id> · PR: <#/url or "none yet">
```

Resolve each:

- **Branch** — must be a feature branch, not the repo default. If the tree has
  uncommitted work, commit it first, then proceed.
- **Beads issue id** — take it from the user's argument if given; else infer from
  the branch name (e.g. `feature/imr-123-*` → `imr-123`); else check claimed
  items (`bd list --status in_progress`). If still ambiguous, ask the user and
  wait — a wrong id closes the wrong issue at stage 4.
- **PR** — likely none yet (no-mistakes creates it). If a PR already exists for
  the branch (`gh pr view --json number,url`), note it and reuse it downstream.

## 1. no-mistakes gate

Validate the committed changes by invoking the **`no-mistakes` skill**, which
owns the pipeline contract — the CLI, the gate loop, `ask-user` escalation, and
recovery. Follow it as written, with the overrides below layered on top.

Its `--intent` is the work's intent: the goal and any notable decisions or
tradeoffs from this session, **not** the full beads body.

Overrides for this flow:

- Run attended, without `--yes` — this flow has a human review pause at stage 3,
  and `--yes` would auto-resolve the `ask-user` findings meant for the user.
- **Stop at `checks-passed`.** The no-mistakes skill would hand the PR to the
  user to merge there; here that outcome is a handoff to stage 2 instead. Do not
  ask the user to merge yet.
- **Severity cap.** Count the review-step gate rounds you resolve. Rounds 1–3 act
  on every finding. From round 4 on, act only on `warning` and above; accept
  anything below warning as-is so the run advances, and carry those skipped
  findings to the final report. Round 1 catches the real defects and rounds 2–3
  the fallout from fixing them, so past that a nit costs more in churn commits
  and regression risk than it is worth.

**Handoff:** the target outcome is `checks-passed` (validated, CI green, not yet
merged — merging happens after stage 3). Proceed to stage 2 reusing the PR (URL is
in the `help` line). A `failed`/`cancelled` outcome or an `error:` is a stage
failure — report and stop.

## 2. pr-review-loop

Invoke the `pr-review-loop` skill, targeting the PR from stage 1. If it stops on
a cap/timeout with unresolved findings, report that and get explicit approval
before advancing past open review findings.

## 3. Review pause

Once stage 2 completes, present the PR URL and ask the user — with
`AskUserQuestion` — which they want:

- **Open tuicr** (recommend this first) — open the PR in a tuicr review pane so
  they can read the diff and leave comments.
- **Skip to merge** — no local review; go straight to 3b. Both paths still pass
  through the re-sign step.

### 3a. Open tuicr (only if chosen)

Open the review in a **new tab in the user's current Orca workspace**, not the
PR's own worktree — a terminal created against another worktree lands in a
background workspace the user has to go hunting for. Load the `orca-cli` skill,
resolve the executable, then:

```bash
orca worktree current --json                       # confirm the active workspace
orca terminal create --worktree active --title "tuicr PR <#>" \
  --command "tuicr pr <#>" --json
orca terminal switch --terminal <handle> --json    # bring the tab to the front
```

`tuicr pr <#>` resolves the PR from the repo's `origin`, so running it from the
current worktree is fine even when the PR branch is checked out elsewhere.

Then **wait for the user to say their comments are ready.** Read them with the
`tuicr` skill (`tuicr review comments --session gh:<owner>/<repo>/pr/<#>`), treat
them as blocking feedback (`issue` first), fix, push, and re-present. Do not
write agent-authored comments into their session. Loop until they say the review
is done.

### 3b. Re-sign the pipeline's commits

no-mistakes runs with commit signing turned off, so its auto-fix commits — and
any its background CI monitor pushed — carry no signature. Re-sign the branch
here, at the last possible moment: that monitor stays live until the PR merges,
so an earlier rewrite just leaves fresh unsigned commits behind you.

Check first, and **skip the whole step if there is nothing to fix** — a
needless force-push costs a full CI re-run:

```sh
BASE=$(gh pr view <#> --json baseRefName -q .baseRefName)
git log --format='%h %G? %s' "origin/$BASE..HEAD"
```

`%G?` is `G` for a good signature and `N` for none. If any line reads `N`:

```sh
git fetch origin
git rebase --force-rebase --gpg-sign "$(git merge-base origin/$BASE HEAD)"
git push --force-with-lease
```

Rebase onto the **merge base**, not `origin/$BASE`. That rewrites the commits in
place with signatures and nothing else; rebasing onto the live base branch would
also drag in whatever landed there since, turning a signing pass into a content
change that can conflict.

- `--force-with-lease` refuses the push if the pipeline pushed something you have
  not fetched. Treat a refusal as a stop: fetch, re-read the log, and start the
  check over rather than forcing past it.
- Rewrite only the feature branch. Never rewrite the base.
- Verify no line still reads `N` afterwards, and let CI go green on the new head
  before merging. `U` means signed but the signer is not in this machine's
  `allowed_signers` — signed is what this step is for, so treat it as done.
- If signing itself fails (`error: Load key ... agent refused operation`), the
  1Password SSH agent is not serving the key — load the `1password` skill.
- If the CI monitor pushes again after the rewrite, run this step once more.

### 3c. Merge

Either path converges here: **wait for the user to prompt you to continue.**
Merge only once they do, however the repo merges (merge queue, `gh pr merge`, or
the user merging it themselves).

## 4. Hand the beads issue back

**Never close the issue yourself** — closing is the user's call, even after the
PR merges. Do not run `bd close`.

Once the PR is `MERGED` (`gh pr view <#> --json state`), leave the issue
`in_progress`, report its state and the merged PR, and tell the user it is ready
for them to close. Close it only if they explicitly tell you to in that turn.

Still persist any updates you *did* make (`bd dolt push` if that is how the repo
syncs).

## Final report

Summarize the outcome in one compact block: PR merged (link), beads issue id +
its (still open) status and that it awaits the user's close, any stage that was
skipped, capped, or needs follow-up, and any low-severity findings dropped by
the stage 1 severity cap.

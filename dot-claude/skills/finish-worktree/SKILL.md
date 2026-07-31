---
name: finish-worktree
description: Finish development on a worktree end-to-end — take committed work from validation through a merged PR and a closed beads issue.
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

Validate the committed changes through the no-mistakes pipeline. Drive its CLI
directly (the Skill tool cannot invoke it from here) — the CLI is self-describing:
`no-mistakes axi run --help` lists the flags, and every return prints a `help[]`
list of the next commands (errors print `error:` + `help`). Follow those.

Start with the work's intent — a concise statement of the goal and any notable
decisions/tradeoffs from this session, **not** the full beads body:

```sh
no-mistakes axi run --intent "<what the user set out to accomplish>"
```

Then loop: each return is either a `gate:` (respond per its `help[]` lines) or an
`outcome:` — repeat until an `outcome:`.

Judgment rules the `help[]` output won't teach you:

- A `gate:` finding marked `ask-user` is the user's call — **escalate it to them
  verbatim** (id, file, description). `auto-fix`/`no-op` findings you may drive
  yourself.
- Run attended, without `--yes` — this flow has a human review pause at stage 3,
  and `--yes` would auto-resolve the `ask-user` findings meant for the user.
- `axi run`/`axi respond` block for minutes (review, test, CI). A slow call is
  working — check `axi status` separately rather than cancelling or re-issuing.
- The pipeline owns fixes (`--action fix`) and its background CI monitor owns
  rebases — leave both to it.
- **Severity cap.** Count the review-step gate rounds you resolve. Rounds 1–3 act
  on every finding. From round 4 on, act only on `warning` and above; accept
  anything below warning as-is so the run advances, and carry those skipped
  findings to the final report. Round 1 catches the real defects and rounds 2–3
  the fallout from fixing them, so past that a nit costs more in churn commits
  and regression risk than it is worth.

**Handoff:** the target outcome is `checks-passed` (validated, CI green, not yet
merged — merging happens after stage 3). Proceed to stage 2 reusing the PR (URL is
in the `help` line). A `failed`/`cancelled` outcome or an `error:` is a stage
failure. If you hit a gate or error the `help[]` lines don't resolve, read
`~/.claude/skills/no-mistakes/SKILL.md` for the full contract before proceeding.

## 2. pr-review-loop

Invoke the `pr-review-loop` skill, targeting the PR from stage 1. If it stops on
a cap/timeout with unresolved findings, report that and get explicit approval
before advancing past open review findings.

## 3. Review pause

Once stage 2 completes, present the PR URL and ask the user — with
`AskUserQuestion` — which they want:

- **Open tuicr** (recommend this first) — open the PR in a tuicr review pane so
  they can read the diff and leave comments.
- **Skip to merge** — no local review; go straight to the merge step below.

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

### 3b. Merge

Either path converges here: **wait for the user to prompt you to continue.**
Merge only once they do, however the repo merges (merge queue, `gh pr merge`, or
the user merging it themselves).

## 4. Close the beads issue

Once the PR is `MERGED` (`gh pr view <#> --json state`), close the backing issue:

```bash
bd close <id> --reason "Merged PR <#/url>"
```

Then persist per the beads skill's convention (`bd dolt push` if that is how the
repo syncs). Verify with `bd show <id>` that status is closed.

## Final report

Summarize the outcome in one compact block: PR merged (link), beads issue closed
(id), any stage that was skipped, capped, or needs follow-up, and any
low-severity findings dropped by the stage 1 severity cap.

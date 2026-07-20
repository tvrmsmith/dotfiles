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
  wait — a wrong id closes the wrong issue at stage 5.
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

**Handoff:** the target outcome is `checks-passed` (validated, CI green, not yet
merged — merging is stages 3–4's job). Proceed to stage 2 reusing the PR (URL is
in the `help` line). A `failed`/`cancelled` outcome or an `error:` is a stage
failure. If you hit a gate or error the `help[]` lines don't resolve, read
`~/.claude/skills/no-mistakes/SKILL.md` for the full contract before proceeding.

## 2. pr-review-loop

Invoke the `pr-review-loop` skill, targeting the PR from stage 1. If it stops on
a cap/timeout with unresolved findings, report that and get explicit approval
before advancing past open review findings.

## 3. Review pause

Once stage 2 completes, remind the user that this is where they normally review
the code, present the PR URL, and **wait for them to prompt you to continue.**
Merge only once they do.

## 4. Sequential CI-gated merge

Merge the PR via the `sequential-ci-gated-pr-merge` skill as a single-PR train
(pass the one PR from stage 1). Honor its own stop conditions (conflict, failed
check, re-sync cap). Confirm the PR is `MERGED` before stage 5.

## 5. Close the beads issue

Once the merge is confirmed, close the backing issue:

```bash
bd close <id> --reason "Merged PR <#/url>"
```

Then persist per the beads skill's convention (`bd dolt push` if that is how the
repo syncs). Verify with `bd show <id>` that status is closed.

## Final report

Summarize the outcome in one compact block: PR merged (link), beads issue closed
(id), and any stage that was skipped, capped, or needs follow-up.

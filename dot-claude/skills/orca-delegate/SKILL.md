---
name: orca-delegate
description: File one task in the target repo's issue tracker, then hand it to a Claude worker in a new Orca worktree and move on.
disable-model-invocation: true
---

# Orca Delegate

Turn one task from this session into a **tracker row** in the repo where the work lands, then
spawn a Claude **worker** in a fresh Orca worktree of that repo to complete it. Delegation is
**fire-and-forget**: once the worker is running, this session reports and returns to its own
work. The row is the durable record. The human follows the worker in Orca's sidebar and releases
it with `/orca-fan-in` or `/finish-worktree`.

Several tasks at once, or results that this session should wait on, belong to `/orca-fan-out`.

Resolve the CLI once per the `orca-cli` skill's rules; below, `ORCA` is that executable.

## 1. Pin the task and the target repo

Take the task from the arguments, else from the task under discussion. The **target repo** is the
one whose code changes, which may not be this session's repo. Find it in `ORCA repo list --json`
and keep its selector (`id:<id>`) and its path. When Orca has not registered it, say so and stop:
`ORCA repo add` is the human's call.

Capture a kebab-case slug (≤40 chars), a title, and a body holding the goal, the decisions made in
this session, and the acceptance criteria. The worker starts from the repo and this row alone.

Done when a worker holding only the target repo and the body could start without asking this
session anything. Walk the conversation for decisions about the task rather than summarising
from memory.

## 2. Find the target repo's tracker

The target repo's `CLAUDE.md` or `AGENTS.md` names its tracker and its conventions for type,
priority, and labels. Read it and follow it. When it names none:

- `.beads/` at the repo root means beads.
- Otherwise a GitHub `origin` means GitHub Issues.

When neither applies, or the signals disagree, ask the human.

## 3. Confirm

Print one block: target repo, tracker, title, slug, branch (`<slug>`), the body, and the skill
slot for the brief. Recommend `/implement-with-subagents` for the slot, since it ends at a commit
on a feature branch handed off to `no-mistakes`. The human may swap it for a plain brief, `/tdd`,
or another skill.

**Wait for explicit approval.** Filing a GitHub or Jira issue publishes it, so nothing gets
created before the yes.

## 4. File the row

Write the body to a temp file, then create the row in the target repo. Leave it unclaimed: the
worker claims it.

**Beads.**

```text
bd -C <repo-path> create --title "..." --body-file <file> --type=task --priority=2 --json
```

**GitHub Issues.** The command prints the issue URL, whose last segment is the number.

```text
gh issue create -R <owner>/<repo> --title "..." --body-file <file>
```

**Any other tracker** (Jira through the `acli` skill, for one). Use its own CLI with the same
title and body, and name to the human the command you ran.

Read the row back before going on: `bd -C <repo-path> show <id> --json`,
`gh issue view <number> -R <owner>/<repo> --json number,url`, or the equivalent. The id that read
returns is the id the brief carries.

## 5. Write the brief

Follow step 6 of [`orca-fan-out`](../orca-fan-out/SKILL.md), worktree variant, with the skill slot
from step 3. Two differences:

- The tracker line names the row step 4 filed: `Bead: <id>`, `Issue: <owner>/<repo>#<number>`, or
  `Jira: <KEY>`. `/orca-fan-in` reads each form.
- `Constraints:` points at the row, which already carries this session's decisions.

## 6. Spawn

```text
ORCA status --json
ORCA worktree create --repo <selector> --name <slug> <lineage> \
  --agent claude --prompt '<brief>' --comment '<tracker ref>' --json
```

- `<lineage>` is `--parent-worktree active` when the target repo is this session's repo, and
  `--no-parent` for any other repo.
- A GitHub row also gets `--issue <number>`, which links the issue in Orca. `--comment` puts the
  tracker ref on the worktree for every tracker.

Then follow `orca-fan-out` step 7 from "Read the worker handle" through its **spawned** criterion,
including [`worktree-spawn.md`](../orca-fan-out/references/worktree-spawn.md).

When the spawn fails or the `tui-idle` wait times out, the row already exists. Report the exact
error and the row ref, leave the row open for a retry, and stop. Report the failure rather than
retrying with different flags.

## 7. Report and move on

Print one block: the row ref and URL, worktree id, branch, and worker handle. Add once that
removing the worktree deletes its branch, so the human releases the worker through
`/orca-fan-in` or `/finish-worktree`, both of which record the commit sha on the row.

Then return to this session's work. Nothing here waits on the worker. A `[fan-out]` line that
arrives later is the worker's `/orca-fan-in`: print it and carry on.

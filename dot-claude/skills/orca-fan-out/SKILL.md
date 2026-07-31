---
name: orca-fan-out
description: Spawn this session's discussed task set across Orca workers (tabs or child worktrees) and collect their results as they land; also recovers a batch whose orchestrator session you have lost.
disable-model-invocation: true
---

# Orca Fan-Out

Spread the tasks **already discussed in this session** across Orca **workers** — one Claude
agent per task, each in a tab of this workspace or in its own child worktree — then go **idle**.

Each worker's result comes back later as one line pushed into this session by `/orca-fan-in`,
which the **human** invokes in the worker's session once satisfied with the work. Idle means
this session spawns, reports, and waits for that push, writing nothing along the way.

## 0. Route

**Recovery branch.** If this invocation asks to *find* or *recover* a batch rather than start
one — "find my batch", "where's my batch", "recover my fan-out", "which session was the
orchestrator", "list running fan-outs" — read `references/recovery.md` and follow it instead of
steps 1-9 below.

## Fan-out is for human-in-the-loop work only

Every worker is a session a human will visit, judge, and release.

| Situation | Tool |
|---|---|
| Work that should run to completion unattended | `Agent` tool subagent |
| Supervision, blocking ask/reply, decision gates, a task DAG | `orchestration` skill |
| One task, full ownership transfer, this session stops | `orca-cli` skill (handoff) |

Workers are Claude. If a task names `codex`, `omp`, `pi`, or `grok`, say fan-out is Claude-only
and leave that task out of the batch.

Resolve the CLI once per the `orca-cli` skill's rules; below, `ORCA` is that executable.

## 1. Collect the task set

Take the tasks from this conversation. Arguments narrow or override the set (`/orca-fan-out
tasks 2 and 4 only`). If the session has no clear task set, say so and stop.

Per task capture: a kebab-case slug (≤40 chars), a one-line goal, the bead id when the task has
one, whether it lands committed code, and what it depends on.

Done when **every** task discussed in this session lands in exactly one bucket: a batch row, a
deferred row (step 3), or excluded as non-Claude. Walk the conversation to confirm that, rather
than listing what comes to mind.

## 2. Classify: tab or child worktree

The axis is **branch and commits**, not writes.

- **Child worktree** — the task lands committed code: its own branch, commits, a PR.
- **Tab in this workspace** — human-gated work that commits nothing and needs no branch: walking
  a log, an interactive review, a scratch doc, recon the human will read. A task that edits files
  in a scratch path but commits nothing is a tab.

## 3. Hold back dependents

Any task whose input is another task's output stays out of the batch. List it as **deferred**,
naming the task it waits on; the human fans the deferred rows out later.

## 4. Ask: sequential or parallel

- **Parallel** — every row spawns now.
- **Sequential** — one worker at a time; the next row spawns when the previous result lands.

Sequential's queue lives only in this conversation, which is why step 9 reprints it on every
wake. A sequential batch parked on a worker the human never visits is the gate working.

## 5. Confirm before spawning

Print one row per task — slug, target (`tab`/`worktree`), bead, one-line reason — plus the mode
and the deferred list. **Wait for explicit approval.** Apply any reclassification the human
asks for, then spawn.

Ask, in the same breath, **whether any row's brief should open with a skill invocation** — the
`/<skill> <args>` slot in step 6. Name the row and the skill you would use, or say you propose
none, and let the human correct it. This is not inferable from the task text: `/implement`,
`/tdd`, and a bare brief all describe the same work, and the choice changes how the worker
opens. Asking costs one line; guessing wrong costs a whole worker session.

## 6. Write the brief

Pass only what the worker cannot discover: the task, decisions made in this session, and
pointers. Point at `CLAUDE.md`, skill bodies, and bead descriptions rather than inlining them.

```text
/<skill> <args>            <- optional, first characters only
<task, one paragraph>
Slug: <slug>               <- the name step 9 tallies on
Constraints: <decisions from this session that are not in the bead>
Bead: <id>                 <- omit when the task has none
Expected output: <the artifact to produce>
No branch, no commits.     <- tab briefs end here
Branch: <branch>           <- worktree briefs end here instead; step 7 fills it in
```

- The leading slash slot works: a brief whose first characters are `/skill args` invokes that
  skill in the worker with its arguments intact, including user-invocation-only skills. Whether
  a row uses it is the human's call, asked in step 5 — not something to infer from the task.
- **A slash command consumes its line, not the message.** The slots below it ride in the same
  prompt and reach the worker as the invocation's arguments, so a slash-led brief is still one
  delivery and still carries every slot. The slash line is never the whole brief — a row whose
  task is fully described by `/<skill> <args>` still gets its `Slug:`, `Bead:`, and
  `Expected output:` lines underneath.
- The `Slug:` slot carries this row's kebab-case slug from step 1, verbatim — the same string
  step 7 passes to `worktree create --name` and `terminal create --title`. It is the name this
  session's step-9 tally matches on and the only source the worker can trust for it, so the
  worker's result line must reproduce it exactly.
- The last line is one variant or the other, never both: a tab brief ends `No branch, no
  commits.`, a worktree brief ends `Branch: <branch>`. That branch does not exist yet; step 7
  fills the line in before the worker launches.
- Beads are pre-created elsewhere. The `Bead:` slot passes the id through; the worker claims and
  closes that bead itself.
- A worktree row's `Expected output:` line ends by requiring the worker to **name its commit sha
  and branch in the bead's close reason**. The bead outlives the worktree; removing a worktree
  deletes its branch, and that recorded sha is then the only handle left on the commit. Recovery
  (`references/recovery.md`) reads it.
- In a repo with no beads DB, drop the `Bead:` line; the worker's result line points at a PR,
  branch, or path instead.
- The brief contains exactly the slots in the template above; nothing about done, because the
  human decides done.
- The brief is embedded below as `"<brief>"` inside a single-quoted `--command`, or passed as a
  single-quoted `--prompt`, so keep it free of both single and double quotes — a double quote
  splits the argument and truncates the brief. Rephrase rather than escape.

## 7. Spawn

Confirm the app with `ORCA status --json` before spawning anything.

Canonicalize this session's handle once. This is the address workers push to, and `terminal
list` hands out aliases for the same tab:

```text
ORCA terminal show --terminal "$ORCA_TERMINAL_HANDLE" --json     # → result.terminal.handle
```

Orca injects `ORCA_TERMINAL_HANDLE` into every managed terminal it runs. If it is empty, find
this session's terminal in `ORCA terminal list --worktree active --json` and canonicalize that
one through `terminal show` instead.

**Tab worker.** The inline env prefix is the only way a tab worker can find this session:

```text
ORCA terminal create --worktree active --title "<slug>" \
  --command 'ORCA_FANOUT_ORCHESTRATOR=<handle> claude-launcher --dangerously-skip-permissions "<brief>"' --json
```

**Worktree worker.** One command — `worktree create` launches the agent itself via `--agent` and
delivers the brief via `--prompt`, no `terminal create` needed:

```text
ORCA worktree create --name <slug> --parent-worktree active \
  --agent claude --prompt '<brief>' --json      # → result.worktree.id
                                                #   result.worktree.branch
                                                #   result.agentTerminalHandle
```

The brief must therefore be finished before the command runs, so its `Branch:` line names the
branch the slug will produce — `<slug>`, which is what `--name` derives it from. Confirm against
`result.worktree.branch` in the output.

Read the worker handle from `result.agentTerminalHandle`; older runtimes return only
`result.startupTerminal.handle`, and may return neither for folder-based repos.

A worktree worker needs no env prefix: it self-resolves this session from `cliProvenance.callerTerminalHandle` on its own
worktree record, which `worktree create` just stamped with an alias of this session's terminal —
the worker canonicalizes that alias on its side.

Use `--parent-worktree active` — workers are children of this workspace. Reach for
`--no-parent` only when the human calls a task unrelated to this line of work.

Spawn rows one at a time. In sequential mode, spawn only the first. Every row, tab or worktree,
waits for its Claude to finish booting before you read it — otherwise the read catches a
still-booting TUI:

```text
ORCA terminal wait --terminal <handle> --for tui-idle --timeout-ms 120000 --json
ORCA terminal read --terminal <handle> --json
```

A new worktree can stop on Claude's bypass-permissions consent prompt before the brief runs, and
bare `worktree create` can leave a fallback shell. For a worktree row, read
`references/worktree-spawn.md` and follow it — it picks up from that wait and read.

On a slash-led row, confirm the read shows the invoked skill running **and** the slots that
followed it in the same prompt — a worker that lost its `Slug:` line falls back to a tab title
Orca rewrites from agent activity.

A row counts as **spawned** when a read shows the brief running in the worker and its canonical
handle is recorded — for a worktree row, that is the confirming read after working through
`references/worktree-spawn.md`, so no consent prompt is pending and no fallback shell is left
open. That is the whole criterion for both row types.

When the `tui-idle` wait times out, that worker never started: report it, leave the worker be,
name it as **not delivered** in the step-8 roster, and keep it out of the step-9 outstanding
tally — nothing is coming back from a worker that did not start.

## 8. Report, then idle

Print the roster: slug, target, worktree id, terminal handle, brief delivered. State that each
result arrives when the human runs `/orca-fan-in` in that worker's session.

Close the roster with the durability warning, once, whenever the batch holds a worktree row:
**removing a worktree deletes its branch**, so a worker torn down before `/orca-fan-in` leaves
its commit dangling and reachable only through a sha recorded elsewhere. A worker's work is
durable once it is merged, or once its sha and branch are in its bead's close reason. Then stop.

## 9. On wake

A push arrives as an ordinary user turn:

```text
[fan-out] <slug> <ok|failed|blocked> — <one-sentence outcome>; details: <bead id / PR / branch / path>
```

1. Split the input on the literal `[fan-out]` — two pushes landing together merge into one
   message. Treat each fragment as its own result; when one looks truncated, read its bead
   rather than guessing.
2. Print each parsed result.
3. Print ONE tally naming **every** outstanding slug, on every wake even when nothing else
   changed — the queue lives only in this conversation, and reprinting it in full is what keeps
   it alive across a compaction:
   `3/5 landed — outstanding: docs-pass, migration-check` (plus `— next in queue: <slug>` in
   sequential mode).
4. Sequential mode only: spawn the next row (step 7).
5. Stop. Reviewing, merging, and opening PRs belong to the human.

## Failures

- This session's own handle is unresolvable: spawn the worktree rows only, and name the tab rows
  that could not start. Worktree workers are unaffected — they self-resolve from provenance.
- One spawn fails: report the exact error, keep the other spawns, and name what did not start.
  Report the failure rather than retrying with different flags.
- `terminal_handle_stale`: re-acquire with `ORCA terminal list --worktree <selector> --json`,
  canonicalize with `terminal show`, and use the replacement alone.
- A push never arrives: leave the row in the outstanding list; the human tracks it in Orca's
  sidebar.
- A worker's worktree was removed before its push: the row is gone from every Orca listing and
  its branch with it. Follow `references/recovery.md`, which starts from the bead.

---
name: orca-fan-out
description: Lightweight fan-out of an already-discussed task set across Orca agents — classify each task as same-worktree tab vs child worktree, confirm the split, spawn, report. No DAG, no coordinator loop.
disable-model-invocation: true
---

# Orca Fan-Out

Take the set of tasks **already discussed in this session** and spread them across Orca
agents in one pass. Each task lands either in a new agent tab in the current workspace or
in a new child Orca worktree. Then stop.

This is the cheap alternative to `/orchestration`: no task DAG, no dispatch records, no
`worker_done` waits, no coordinator loop. Fire and forget is the default — the user relays
worker completions back here when they matter.

## Use / don't use

| Situation | Tool |
|---|---|
| Several tasks from this conversation, want them running in parallel now | this skill |
| Need supervision, blocking ask/reply, decision gates, task DAG | `orchestration` skill |
| One task, full ownership transfer, this agent stops | `orca-cli` skill (handoff) |
| Work that stays inside this agent's context (search, read-only recon) | `Agent` tool subagent |

Resolve the CLI once per the `orca-cli` skill's rules (`ORCA_CLI_COMMAND` → `orca-dev` in a
dev checkout → `orca-ide` on Linux outside Orca → `orca`). Below, `ORCA` is that
executable. Confirm the app is up with `ORCA status --json` before spawning anything.

## 1. Collect the task set

Take the tasks from the current conversation. Arguments to the slash command narrow or
override the set (e.g. `/orca-fan-out tasks 2 and 4 only`).

If the session has no clear task set, say so and stop — do not invent one.

For each task capture: a kebab-case slug (≤40 chars), one-line goal, whether it writes
files, and any skill it must run.

## 2. Classify: tab or child worktree

**Child worktree** if *any* of these hold:

- Task edits files, and another task (or this session) may edit the same checkout concurrently
- Task needs its own branch, commits, or PR
- Task runs builds, test suites, servers, or migrations that mutate shared checkout state
- Task outlives the current worktree (must survive its merge/cleanup)

**Tab in the current workspace** only if *all* hold:

- Read-only or output-only: research, review, log/diff analysis, doc writing to a scratch path
- No branch of its own
- Nothing else will be writing the same files while it runs

Tie-break: if it writes, give it a worktree. A wasted worktree is cheap; two agents
stomping one checkout is not.

## 3. Confirm before spawning

Print one row per task — slug, target (`tab` / `worktree`), agent, one-line reason — and
**wait for explicit approval**. Do not spawn on assumption. Apply any reclassification the
user asks for, then proceed.

## 4. Spawn

Default agent is `claude` unless the task or user says otherwise (`codex`, `omp`, `pi`,
`grok` are also valid ids).

Tab in current workspace:

```text
ORCA terminal create --worktree active --title "<slug>" --command "claude" --json
ORCA terminal wait --terminal <handle> --for tui-idle --timeout-ms 120000 --json
ORCA terminal send --terminal <handle> --text "<brief>" --enter --json
```

Child worktree:

```text
ORCA worktree create --name <slug> --parent-worktree active --agent claude --prompt "<brief>" --json
```

- `--parent-worktree active` is deliberate: these are children of the current workspace.
  Use `--no-parent` only when the user calls a task unrelated to the current line of work.
- Read the worker handle from `result.agentTerminalHandle`; older runtimes return only
  `result.startupTerminal.handle`. If neither is present, get it from
  `ORCA terminal list --worktree id:<repoId>::<newWorktreePath> --json`.
- Never pair `worktree create --agent` with a follow-up `terminal create` of the same agent.
- Spawn tasks one after another; each command is fast and independent.

## 5. Writing the brief

Per the global delegating rules, pass only what the worker cannot discover: the task, the
decisions and constraints agreed in this session, and pointers (bead id, file path, PR
number). Do not inline `CLAUDE.md`, skill bodies, or ticket descriptions.

**Running a user-invocable-only skill:** those skills have
`disable-model-invocation: true`, so the worker will not pick them up from a description.
The slash command must be the **first characters of the prompt**, arguments after it:

```text
/comprehensive-code-review changes on this branch vs origin/main
```

The Claude TUI opens a command palette on a leading `/`. After sending, `ORCA terminal read
--terminal <handle> --json` once and confirm the command registered with its arguments
intact; if the palette swallowed or mangled the line, re-send.

## 6. Report and stop

Print the final table: slug, target, worktree id (for worktrees), terminal handle, and
whether the prompt was confirmed delivered. Then stop — no polling, no waiting.

Wait on workers only if the user explicitly asks; then use
`ORCA terminal wait --terminal <handle> --for tui-idle --timeout-ms <ms> --json` followed by
`ORCA terminal read`.

## Failures

- Spawn fails for one task: report the exact error, keep the other spawns, and list what
  did not start. Do not silently retry with different flags.
- `terminal_handle_stale`: re-acquire with `terminal list` and use the replacement only —
  never dual-send to old and new handles.
- `tui-idle` wait times out: report it and leave the prompt unsent rather than blind-sending
  into a terminal that may not be ready.

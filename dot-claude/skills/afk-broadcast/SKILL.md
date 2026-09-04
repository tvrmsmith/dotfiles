---
name: afk-broadcast
description: Send /afk to every recently active Claude session in Orca.
disable-model-invocation: true
---

# AFK Broadcast

Trevor is leaving and wants his running sessions told, without opening each tab. Find the
Claude sessions Orca knows about, send `/afk` to each, report what landed. Then stop: he is
already gone.

Arguments override the window and carry a note (`/afk-broadcast 2h back at 4pm`). Default
window is 6 hours; the rest of the argument rides along on the `/afk` line.

## 1. Resolve the CLI

Follow the `orca-cli` skill's resolution rules; `ORCA` below is the executable it picks.
Confirm the runtime with `ORCA status --json` before anything else.

## 2. Find the sessions

```text
ORCA terminal list --json
```

A terminal is a target when all of these hold:

- `agentIdentity` is `claude`
- `orphaned` is false and `connected` is true
- `lastOutputAt` (epoch ms) is inside the window. The field is sometimes null: leave those out
  of the roster and list them under the report's blind spot, since no activity time means no
  evidence the session is live.

Drop this session. Canonicalize its handle with
`ORCA terminal show --terminal "$ORCA_TERMINAL_HANDLE" --json`, then drop that `handle` and
every terminal sharing its `tabId` — `terminal list` hands out aliases for one tab. When
`ORCA_TERMINAL_HANDLE` is empty, keep the full list and say in the report that this session may
have messaged itself.

## 3. Print the roster

One row per target: title, worktree basename, branch, minutes since `lastOutputAt`, handle.
Print it and go straight to sending — no approval step. If nothing matched, say so and stop.

## 4. Send

Per target:

```text
ORCA terminal send --terminal <handle> --text '/afk <note>' --enter
```

The slash command only fires from the first characters of the line, and the whole line becomes
its argument, so keep the note to one plain line with no newlines. A session mid-turn queues
the input and picks it up when it finishes, which is the wanted behaviour — send, do not
interrupt.

## 5. Confirm each one landed

Read each target once the sends are out:

```text
ORCA terminal read --terminal <handle> --json
```

A target is **delivered** when the read shows the AFK skill running or its log. When the read
shows the session still working its previous turn, wait once and read again:

```text
ORCA terminal wait --terminal <handle> --for tui-idle --timeout-ms 60000 --json
```

Still nothing on the second read: call it **queued**, not failed. The input is sitting in that
session's prompt.

On `terminal_handle_stale`, re-acquire from `terminal list`, canonicalize through
`terminal show`, and send once more to the replacement.

## 6. Report

One table: session, `delivered` / `queued` / `failed`, plus the exact error on a failure. Close
with the blind spot — sessions outside Orca (a bare terminal, another machine, a paused
worktree) never appeared in `terminal list` and were not told. Then stop.

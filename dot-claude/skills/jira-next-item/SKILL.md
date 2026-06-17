---
name: jira-next-item
description: Start the next work item from a Jira board. Invoke explicitly (e.g. /jira-next-item) to pick up the next unassigned, To Do work item in board (Rank) order — preferring the active sprint, falling back to the backlog — then assign it (and its subtasks) to yourself, move it to In Progress, and kick off brainstorming on it. Takes an optional board name or ID; defaults to board 987 (project HCON).
---

# Start Next Jira Work Item

Pick up the next thing to work on from a Jira board and start it, end to end:
find the highest-priority startable item, claim it, and begin design work.

"Priority" here means **board order (Rank)** — the order items sit in on the board /
backlog — not the Priority field. Unassigned items in a To Do status are candidates;
items already assigned or past To Do are skipped. The active sprint is preferred; only
if it has nothing startable do we look at the backlog, and a backlog pick is confirmed
with the user before it's pulled into the sprint.

## Prerequisites

- `acli` authenticated (see the `acli` skill). Used for assigns, transitions, viewing a
  ticket, listing the board's sprints, and finding subtasks.
- `curl` + `jq`. Item **selection** and the sprint-add both go through the Jira Agile
  REST API (`acli` can only query a raw `sprint = <id>` JQL — it cannot scope to a
  board's filter, which is exactly the bug this skill must avoid; see Step 2).
- These env vars must be set (they provide REST basic auth) — selection needs them, so
  they are required, not optional: `JIRA_BASE_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN`.
  If any is missing, tell the user to source their environment and stop.
  `JIRA_API_TOKEN` holds a **1Password secret reference** (an `op://...` URI), not the
  literal token, so it must be resolved with `op read` before use. This needs the `op`
  CLI authenticated (see the `1password` skill). Resolve it once up front:

  ```bash
  TOKEN=$(op read "$JIRA_API_TOKEN")   # reused for every REST call below
  ```

## Step 1 — Resolve board, project, and active sprint

Accept an optional argument: a board **name or ID**. Resolve it to a numeric board ID:

- **No argument** → use the default board `987` (project HCON).
- **Numeric argument** → use it directly as the board ID.
- **Text argument** → look it up by name:

  ```bash
  acli jira board search --name "<ARG>" --json | jq -r '.values[] | "\(.id)\t\(.name)"'
  ```

  If exactly one row matches the name, use its ID. If several match, show the list and
  ask the user which one. If none match, say so and stop.

Resolve the active sprint (its ID changes every sprint, so never hardcode it):

```bash
acli jira board list-sprints --id <BOARD> --state active --json \
  | jq -r '.sprints[0] | "\(.id)\t\(.name)"'
```

If there is no active sprint, note it and skip straight to the backlog pass in Step 2.

## Step 2 — Find the next startable item

**Select through the board's own endpoints, not a raw `sprint = <id>` JQL.** A sprint is
just a container of issues; the *board* is a filtered view over it (board 987, for
example, only shows issues whose Team is Bedrock). An issue can sit in the active sprint
yet never appear on the board. Querying `sprint = <id>` returns those off-board issues
too, so the skill would "start" something the user can't even see on their board. The
Agile board endpoints AND the board's saved filter in automatically, so they return
exactly what the user sees. `acli` cannot do this — hence `curl`.

The same predicate drives both passes (board order via `ORDER BY Rank ASC`;
`subTaskIssueTypes()` drops orphan subtasks; `!= Epic` drops epics):

```bash
PRED='assignee is EMPTY AND statusCategory = "To Do" AND issuetype not in subTaskIssueTypes() AND issuetype != Epic ORDER BY Rank ASC'
```

**Sprint pass** (only if there is an active sprint). The board filter + sprint scope are
applied by the endpoint; the predicate is ANDed on via `jql`:

```bash
curl -sS -u "$JIRA_USERNAME:$TOKEN" -G \
  --data-urlencode "jql=$PRED" \
  --data-urlencode "fields=key,summary,issuetype" --data-urlencode "maxResults=1" \
  "$JIRA_BASE_URL/rest/agile/1.0/board/<BOARD>/sprint/<SPRINT_ID>/issue" \
  | jq -r '.issues[0] | "\(.key)\t\(.fields.issuetype.name)\t\(.fields.summary)" // "none"'
```

If this returns a row, that is the next item and it is **already in the sprint and on
the board** — no sprint-add needed. Skip to Step 4 (the assignment actions).

**Backlog fallback** (only if the sprint pass returned nothing, or there is no active
sprint). The `/backlog` endpoint is already board-filtered *and* excludes anything in an
active or future sprint, so the predicate stays identical — no project or `sprint is
EMPTY` clause needed:

```bash
curl -sS -u "$JIRA_USERNAME:$TOKEN" -G \
  --data-urlencode "jql=$PRED" \
  --data-urlencode "fields=key,summary,issuetype" --data-urlencode "maxResults=1" \
  "$JIRA_BASE_URL/rest/agile/1.0/board/<BOARD>/backlog" \
  | jq -r '.issues[0] | "\(.key)\t\(.fields.issuetype.name)\t\(.fields.summary)" // "none"'
```

A row here is the next item and it came from the backlog — it must be confirmed and
pulled into the sprint (Step 3) before being started.

If both passes return nothing, report "no startable items on this board" and stop.

## Step 3 — (Backlog items only) Confirm and pull into the sprint

`acli` cannot move an item into a sprint, so this uses the Jira Agile REST API. Do this
**only** for an item that came from the backlog pass.

1. Show the user the item (key, type, summary) and ask whether it's acceptable to pull
   it into the active sprint. If they decline, stop — nothing has been changed yet.

2. On approval, add it. Reuse the `$TOKEN` resolved in the prerequisites; POST with basic
   auth, capturing the HTTP status so a failure is caught:

   ```bash
   HTTP=$(curl -sS -o /tmp/jira-sprint-add.out -w '%{http_code}' \
     -u "$JIRA_USERNAME:$TOKEN" \
     -X POST -H 'Content-Type: application/json' \
     --data '{"issues":["<KEY>"]}' \
     "$JIRA_BASE_URL/rest/agile/1.0/sprint/<SPRINT_ID>/issue")
   echo "HTTP $HTTP"; cat /tmp/jira-sprint-add.out
   ```

   A successful add returns `204` with an empty body. On any non-2xx status, report the
   status and body and **stop before assigning anything** — don't half-start an item.

## Step 4 — Start the item

With the item selected (and, if it came from the backlog, now in the sprint):

1. Assign the item to the user:

   ```bash
   acli jira workitem assign --key <KEY> --assignee @me
   ```

2. Move it to In Progress:

   ```bash
   acli jira workitem transition --key <KEY> --status "In Progress" --yes
   ```

   If the board's in-progress status has a different name, list the available
   transitions for the item and pick the in-progress one rather than guessing.

3. Assign every subtask of the item to the user too, so the whole unit of work is
   yours. Find them, then assign each:

   ```bash
   # Request at least two fields — `--fields "key"` alone makes acli return null rows.
   acli jira workitem search --jql 'parent = <KEY>' --fields "key,summary" --json \
     | jq -r '.[].key'
   # for each SUBKEY:
   acli jira workitem assign --key <SUBKEY> --assignee @me
   ```

   If the item has no subtasks, skip this.

## Step 5 — Hand off to brainstorming

Fetch the full ticket once so design work starts with real content, not just a key:

```bash
acli jira workitem view <KEY> --json
```

Pull out the summary, the description, and the subtask list. Then invoke the
`superpowers:brainstorming` skill to begin the work, making it explicit that this is a
Jira issue. Pass along:

- the ticket key `<KEY>` — state plainly "We are working on Jira issue <KEY>" so
  brainstorming can re-query Jira (attachments, comments, linked issues) if the seeded
  details aren't enough,
- the summary and description,
- the list of subtasks.

This is the end state of the skill: the item is claimed, in progress, and brainstorming
is underway on it.

## Edge cases

- **Board name matches several boards** → show the candidates, ask which.
- **Board name matches nothing** → say so, stop.
- **No active sprint** → state it, go straight to the backlog pass.
- **Nothing startable in sprint or backlog** → report it, stop.
- **REST sprint-add returns non-2xx** → report status + body, stop before assigning.
- **Missing `JIRA_BASE_URL` / `JIRA_USERNAME` / `JIRA_API_TOKEN`** (needed for selection,
  not just the sprint-add) → tell the user to source their env, stop.
- **`op read` fails / `op` not signed in** (the token is a 1Password reference) → point
  the user at the `1password` skill to re-auth, stop before any REST call.
- **Item in the sprint but not on the board** → impossible by construction now: selection
  goes through the board endpoint, which applies the board's filter, so only board-visible
  items are ever picked. (This is the bug the Step 2 design exists to prevent.)
- **In-progress transition name differs** → list the item's transitions, pick the
  in-progress one instead of failing.
- **Item has no subtasks** → skip the subtask assignment.

# jira-next-item Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a user-invocable `jira-next-item` skill that starts the next unassigned, To Do work item from a Jira board (board/Rank order = priority), preferring the active sprint and falling back to the backlog, then assigns it + subtasks to the user, moves it to In Progress, and hands off to brainstorming.

**Architecture:** A single instructions-only `SKILL.md` at `~/.claude/skills/jira-next-item/`. The agent running the skill executes documented `acli` commands (read, assign, transition) plus one `curl` call to the Jira Agile REST API to add a backlog item to the active sprint. No bundled scripts — matches the existing instruction-only personal skills (`daily-standup`, `morning-routine`).

**Tech Stack:** `acli` (authenticated Atlassian CLI), `curl` + `jq`, Jira Agile REST API. Env vars `JIRA_BASE_URL` / `JIRA_USERNAME` / `JIRA_API_TOKEN` for REST basic auth.

**Spec:** `docs/superpowers/specs/2026-06-11-jira-next-item-skill-design.md`

**Note on testing:** The deliverable is a markdown instruction file, not compilable code — there is no unit-test framework to drive TDD. Verification is done by running the read-only `acli` queries the skill documents (all pre-validated during design) and a guarded live dry-run. Commit after each task.

---

### Task 1: Create skill directory and frontmatter

**Files:**
- Create: `~/.claude/skills/jira-next-item/SKILL.md`

- [ ] **Step 1: Create the directory**

```bash
mkdir -p ~/.claude/skills/jira-next-item
```

- [ ] **Step 2: Write SKILL.md frontmatter + Overview**

Write the file start. The `description` is deliberately factual and scoped (this skill is user-invocable only — no eager keyword bait):

````markdown
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
- These env vars must be set (REST basic auth) — selection needs them, so required:
  `JIRA_BASE_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN`. If any is missing, tell the user to
  source their environment and stop. `JIRA_API_TOKEN` is a 1Password `op://` reference;
  resolve once with `TOKEN=$(op read "$JIRA_API_TOKEN")` and reuse for every REST call.
````

- [ ] **Step 3: Verify the file parses as a skill (frontmatter present)**

Run: `head -5 ~/.claude/skills/jira-next-item/SKILL.md`
Expected: shows `---`, `name: jira-next-item`, the `description:` line, `---`.

- [ ] **Step 4: Commit**

```bash
cd ~/dev/personal/dotfiles
git -C ~/.claude/skills/jira-next-item add SKILL.md 2>/dev/null || true
# Skills live outside the dotfiles repo; commit happens in whatever repo tracks ~/.claude.
# If ~/.claude is a git repo:
git -C ~/.claude add skills/jira-next-item/SKILL.md && git -C ~/.claude commit -m "feat(skill): scaffold jira-next-item frontmatter" || echo "~/.claude not a git repo — skipping commit"
```

---

### Task 2: Document board + active sprint resolution

**Files:**
- Modify: `~/.claude/skills/jira-next-item/SKILL.md` (append "Resolve the board" section)

- [ ] **Step 1: Append the resolution section**

````markdown
## Step 1 — Resolve board and active sprint

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
(Project key is not needed — Step 2 scopes by board, not project.)
````

- [ ] **Step 2: Verify the resolution command against the default board**

Run:
```bash
acli jira board list-sprints --id 987 --state active --json | jq -r '.sprints[0] | "\(.id)\t\(.name)"'
```
Expected: prints a sprint id + name (e.g. `44250<TAB>Bedrock Sprint 251`).

- [ ] **Step 3: Commit**

```bash
git -C ~/.claude add skills/jira-next-item/SKILL.md && git -C ~/.claude commit -m "feat(skill): jira-next-item board + sprint resolution" || echo "~/.claude not a git repo — skipping commit"
```

---

### Task 3: Document item selection (sprint pass + backlog fallback)

**Files:**
- Modify: `~/.claude/skills/jira-next-item/SKILL.md` (append "Find the next item" section)

- [ ] **Step 1: Append the selection section**

````markdown
## Step 2 — Find the next startable item

**Select through the board's Agile endpoints, not a raw `sprint = <id>` JQL.** A sprint is
just a container of issues; the *board* is a filtered view over it (board 987, for example,
only shows issues whose Team is Bedrock). An issue can sit in the active sprint yet never
appear on the board. Querying `sprint = <id>` returns those off-board issues too, so the
skill would "start" something the user can't even see on their board. The Agile board
endpoints AND the board's saved filter in automatically, so they return exactly what the
user sees. `acli` cannot do this — hence `curl`.

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

If this returns a row, that is the next item and it is **already in the sprint and on the
board** — no sprint-add needed. Skip to Step 3, going straight to the assignment actions.

**Backlog fallback** (only if the sprint pass returned nothing, or there is no active
sprint). The `/backlog` endpoint is already board-filtered *and* excludes anything in an
active or future sprint, so the predicate stays identical — no project or `sprint is EMPTY`
clause needed:

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
````

- [ ] **Step 2: Verify both board endpoints return board-filtered, board-ordered results**

Run (substitute the sprint id from Task 2):
```bash
TOKEN=$(op read "$JIRA_API_TOKEN")
PRED='assignee is EMPTY AND statusCategory = "To Do" AND issuetype not in subTaskIssueTypes() AND issuetype != Epic ORDER BY Rank ASC'
curl -sS -u "$JIRA_USERNAME:$TOKEN" -G --data-urlencode "jql=$PRED" --data-urlencode "fields=key,summary,issuetype" --data-urlencode "maxResults=3" "$JIRA_BASE_URL/rest/agile/1.0/board/987/sprint/44250/issue" | jq -r '.issues[] | "\(.key)\t\(.fields.issuetype.name)\t\(.fields.summary)"'
curl -sS -u "$JIRA_USERNAME:$TOKEN" -G --data-urlencode "jql=$PRED" --data-urlencode "fields=key,summary,issuetype" --data-urlencode "maxResults=3" "$JIRA_BASE_URL/rest/agile/1.0/board/987/backlog" | jq -r '.issues[] | "\(.key)\t\(.fields.issuetype.name)\t\(.fields.summary)"'
```
Expected: each prints up to 3 rows; **no row has issuetype `Sub-task` or `Epic`**, and
every row is an item that actually shows on board 987 (Bedrock-team filtered).

- [ ] **Step 3: Commit**

```bash
git -C ~/.claude add skills/jira-next-item/SKILL.md && git -C ~/.claude commit -m "feat(skill): jira-next-item sprint + backlog selection" || echo "~/.claude not a git repo — skipping commit"
```

---

### Task 4: Document confirm + pull backlog item into sprint (REST)

**Files:**
- Modify: `~/.claude/skills/jira-next-item/SKILL.md` (append "Pull into sprint" section)

- [ ] **Step 1: Append the sprint-add section**

````markdown
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
````

- [ ] **Step 2: Verify the REST endpoint/auth without mutating (GET the sprint)**

This confirms the resolved token authenticates against the Agile API. It only reads.
Run:
```bash
TOKEN=$(op read "$JIRA_API_TOKEN")
curl -sS -o /dev/null -w '%{http_code}\n' -u "$JIRA_USERNAME:$TOKEN" "$JIRA_BASE_URL/rest/agile/1.0/sprint/44250"
```
Expected: `200`. (A `401`/`403` means auth is wrong — note `JIRA_API_TOKEN` is a
1Password `op://` reference, so it must be resolved with `op read`, not used directly.)

- [ ] **Step 3: Commit**

```bash
git -C ~/.claude add skills/jira-next-item/SKILL.md && git -C ~/.claude commit -m "feat(skill): jira-next-item REST sprint-add" || echo "~/.claude not a git repo — skipping commit"
```

---

### Task 5: Document start actions (assign, transition, subtasks)

**Files:**
- Modify: `~/.claude/skills/jira-next-item/SKILL.md` (append "Start the item" section)

- [ ] **Step 1: Append the start-actions section**

````markdown
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
````

- [ ] **Step 2: Verify the subtask query shape (read-only, against a known item)**

Run (any existing HCON key works just to confirm the query parses):
```bash
acli jira workitem search --jql 'parent = HCON-34900' --fields "key,summary" --json | jq -r '.[].key'
```
Expected: prints zero or more subtask keys, no error.

- [ ] **Step 3: Commit**

```bash
git -C ~/.claude add skills/jira-next-item/SKILL.md && git -C ~/.claude commit -m "feat(skill): jira-next-item start actions" || echo "~/.claude not a git repo — skipping commit"
```

---

### Task 6: Document handoff to brainstorming + edge cases

**Files:**
- Modify: `~/.claude/skills/jira-next-item/SKILL.md` (append "Hand off" + "Edge cases" sections)

- [ ] **Step 1: Append the handoff section**

````markdown
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
````

- [ ] **Step 2: Append the edge-cases section**

````markdown
## Edge cases

- **Board name matches several boards** → show the candidates, ask which.
- **Board name matches nothing** → say so, stop.
- **No active sprint** → state it, go straight to the backlog pass.
- **Nothing startable in sprint or backlog** → report it, stop.
- **REST sprint-add returns non-2xx** → report status + body, stop before assigning.
- **Missing `JIRA_BASE_URL` / `JIRA_USERNAME` / `JIRA_API_TOKEN`** (needed for selection,
  not just the sprint-add) → tell the user to source their env, stop.
- **`op read` fails / `op` not signed in** → point the user at the `1password` skill to
  re-auth, stop before any REST call.
- **Item in the sprint but not on the board** → impossible by construction: selection goes
  through the board endpoint, which applies the board's filter, so only board-visible items
  are picked. (This is the bug the Step 2 design exists to prevent.)
- **In-progress transition name differs** → list the item's transitions, pick the
  in-progress one instead of failing.
- **Item has no subtasks** → skip the subtask assignment.
````

- [ ] **Step 3: Verify whole file is coherent and under length budget**

Run:
```bash
wc -l ~/.claude/skills/jira-next-item/SKILL.md
grep -nE 'TODO|TBD|<KEY>|<BOARD>|<SPRINT_ID>|<KEY>' ~/.claude/skills/jira-next-item/SKILL.md | head
```
Expected: line count well under 500; the only `<...>` placeholders are the intended
substitution tokens inside documented commands (no `TODO`/`TBD`).

- [ ] **Step 4: Commit**

```bash
git -C ~/.claude add skills/jira-next-item/SKILL.md && git -C ~/.claude commit -m "feat(skill): jira-next-item brainstorming handoff + edge cases" || echo "~/.claude not a git repo — skipping commit"
```

---

### Task 7: Live dry-run verification

**Files:** none (manual verification)

- [ ] **Step 1: Invoke the skill end-to-end on the default board**

In a Claude session, run `/jira-next-item`. Confirm it:
1. resolves board 987 → active sprint,
2. finds a sprint item via the board endpoint (board-filtered, board order, no subtask/epic),
3. for a sprint item, skips the sprint-add and goes straight to claiming,
4. assigns it to you, moves it to In Progress, assigns its subtasks,
5. hands off to brainstorming framed as "working on Jira issue HCON-XXXX".

Expected: the item shows as In Progress + assigned to you in Jira, and brainstorming
starts with the ticket summary/description in context.

- [ ] **Step 2: Exercise the backlog + confirm path**

Run `/jira-next-item` at a time when the sprint has no startable items (or temporarily
test by reasoning through a backlog pick). Confirm it asks before pulling the backlog
item into the sprint, and that declining stops cleanly with nothing changed.

Expected: a confirmation prompt appears for backlog items; on accept the item lands in
the sprint (REST `204`) then is claimed; on decline nothing is mutated.

- [ ] **Step 3: Final commit (if anything was tweaked during dry-run)**

```bash
git -C ~/.claude add skills/jira-next-item/SKILL.md && git -C ~/.claude commit -m "fix(skill): jira-next-item dry-run adjustments" || echo "nothing to commit"
```

---

## Self-Review

**Spec coverage:**
- User-invocable only, optional board name/ID arg, default 987/HCON → Task 1 (description) + Task 2 (resolution). ✓
- Board order = Rank, unassigned + To Do, exclude subtasks + epics → Task 3. ✓
- Sprint first, backlog fallback → Task 3. ✓
- Confirm before pulling backlog item into sprint; REST add → Task 4. ✓
- Assign item + subtasks, transition to In Progress → Task 5. ✓
- Fetch full details, hand to brainstorming with key + framing → Task 6. ✓
- Error/edge cases → Task 6. ✓
- Authoring conventions (factual description, inline curl, single file) → Tasks 1–6. ✓

**Placeholder scan:** No `TODO`/`TBD`. The `<KEY>`/`<BOARD>`/`<SPRINT_ID>` tokens are intentional command substitution markers documented in the skill, not plan gaps.

**Consistency:** Command flags match the validated `acli` invocations (`assign --assignee @me`, `transition --status "In Progress" --yes`); selection uses the Agile board endpoints (`/board/<id>/sprint/<sid>/issue`, `/board/<id>/backlog`) with the board filter auto-applied — never a raw `sprint = <id>` JQL, which is the off-board-pick bug. REST auth (`-u "$JIRA_USERNAME:$TOKEN"`, token via `op read`) and the `$PRED` predicate are consistent across Tasks 2–4. Sprint extraction (`list-sprints`) in Task 2 feeds the Task 3 sprint endpoint.

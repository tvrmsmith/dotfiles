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

- `acli` authenticated (see the `acli` skill). All reads, assigns, and transitions go
  through it.
- `jq` for parsing JSON output.
- For pulling a backlog item into the sprint, these env vars must be set (they provide
  REST basic auth): `JIRA_BASE_URL`, `JIRA_USERNAME`, `JIRA_API_TOKEN`. If any is
  missing, tell the user to source their environment and stop before mutating anything.
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

### Task 2: Document board / project / sprint resolution

**Files:**
- Modify: `~/.claude/skills/jira-next-item/SKILL.md` (append "Resolve the board" section)

- [ ] **Step 1: Append the resolution section**

````markdown
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

Derive the project key from the board (the JQL backlog query needs it):

```bash
acli jira board list-projects --id <BOARD> --json | jq -r '.projects[0].key'
```

Resolve the active sprint (its ID changes every sprint, so never hardcode it):

```bash
acli jira board list-sprints --id <BOARD> --state active --json \
  | jq -r '.sprints[0] | "\(.id)\t\(.name)"'
```

If there is no active sprint, note it and skip straight to the backlog pass in Step 2.
````

- [ ] **Step 2: Verify the resolution commands against the default board**

Run:
```bash
acli jira board list-projects --id 987 --json | jq -r '.projects[0].key'
acli jira board list-sprints --id 987 --state active --json | jq -r '.sprints[0] | "\(.id)\t\(.name)"'
```
Expected: prints `HCON`, then a sprint id + name (e.g. `44250<TAB>Bedrock Sprint 251`).

- [ ] **Step 3: Commit**

```bash
git -C ~/.claude add skills/jira-next-item/SKILL.md && git -C ~/.claude commit -m "feat(skill): jira-next-item board/project/sprint resolution" || echo "~/.claude not a git repo — skipping commit"
```

---

### Task 3: Document item selection (sprint pass + backlog fallback)

**Files:**
- Modify: `~/.claude/skills/jira-next-item/SKILL.md` (append "Find the next item" section)

- [ ] **Step 1: Append the selection section**

````markdown
## Step 2 — Find the next startable item

Two passes, sprint first. In both, `ORDER BY Rank ASC` returns items in board order, so
the first row is the highest-priority candidate. `issuetype not in subTaskIssueTypes()`
drops orphan subtasks and `issuetype != Epic` drops epics, leaving real work items
(Story / Task / Bug level).

**Sprint pass** (only if there is an active sprint):

```bash
acli jira workitem search \
  --jql 'sprint = <SPRINT_ID> AND assignee is EMPTY AND statusCategory = "To Do" AND issuetype not in subTaskIssueTypes() AND issuetype != Epic ORDER BY Rank ASC' \
  --fields "key,summary,status,issuetype" --json --limit 1 \
  | jq -r '.[0] | "\(.key)\t\(.fields.issuetype.name)\t\(.fields.summary)"'
```

If this returns a row, that is the next item and it is **already in the sprint** — no
sprint-add needed. Skip to Step 3, going straight to the assignment actions.

**Backlog fallback** (only if the sprint pass returned nothing, or there is no active
sprint). `sprint is EMPTY` scopes to items not in any sprint — the backlog:

```bash
acli jira workitem search \
  --jql 'project = <KEY> AND sprint is EMPTY AND assignee is EMPTY AND statusCategory = "To Do" AND issuetype not in subTaskIssueTypes() AND issuetype != Epic ORDER BY Rank ASC' \
  --fields "key,summary,status,issuetype" --json --limit 1 \
  | jq -r '.[0] | "\(.key)\t\(.fields.issuetype.name)\t\(.fields.summary)"'
```

A row here is the next item and it came from the backlog — it must be confirmed and
pulled into the sprint (Step 3) before being started.

If both passes return nothing, report "no startable items on this board" and stop.
````

- [ ] **Step 2: Verify both queries return board-ordered results**

Run (substitute the sprint id from Task 2):
```bash
acli jira workitem search --jql 'sprint = 44250 AND assignee is EMPTY AND statusCategory = "To Do" AND issuetype not in subTaskIssueTypes() AND issuetype != Epic ORDER BY Rank ASC' --fields "key,summary,issuetype" --json --limit 3 | jq -r '.[] | "\(.key)\t\(.fields.issuetype.name)\t\(.fields.summary)"'
acli jira workitem search --jql 'project = HCON AND sprint is EMPTY AND assignee is EMPTY AND statusCategory = "To Do" AND issuetype not in subTaskIssueTypes() AND issuetype != Epic ORDER BY Rank ASC' --fields "key,summary,issuetype" --json --limit 3 | jq -r '.[] | "\(.key)\t\(.fields.issuetype.name)\t\(.fields.summary)"'
```
Expected: each prints up to 3 rows; **no row has issuetype `Sub-task` or `Epic`**.

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

2. On approval, add it (basic auth from the env vars; capture the HTTP status so a
   failure is caught):

   ```bash
   HTTP=$(curl -sS -o /tmp/jira-sprint-add.out -w '%{http_code}' \
     -u "$JIRA_USERNAME:$JIRA_API_TOKEN" \
     -X POST -H 'Content-Type: application/json' \
     --data '{"issues":["<KEY>"]}' \
     "$JIRA_BASE_URL/rest/agile/1.0/sprint/<SPRINT_ID>/issue")
   echo "HTTP $HTTP"; cat /tmp/jira-sprint-add.out
   ```

   A successful add returns `204` with an empty body. On any non-2xx status, report the
   status and body and **stop before assigning anything** — don't half-start an item.
````

- [ ] **Step 2: Verify the REST endpoint/auth without mutating (GET the sprint)**

This confirms the env vars authenticate against the Agile API. It only reads.
Run:
```bash
curl -sS -o /dev/null -w '%{http_code}\n' -u "$JIRA_USERNAME:$JIRA_API_TOKEN" "$JIRA_BASE_URL/rest/agile/1.0/sprint/44250"
```
Expected: `200`. (A `401`/`403` means the env auth is wrong — fix before relying on the POST.)

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
   acli jira workitem search --jql 'parent = <KEY>' --fields "key" --json \
     | jq -r '.[].key'
   # for each SUBKEY:
   acli jira workitem assign --key <SUBKEY> --assignee @me
   ```

   If the item has no subtasks, skip this.
````

- [ ] **Step 2: Verify the subtask query shape (read-only, against a known item)**

Run (any existing HCON key works just to confirm the query parses):
```bash
acli jira workitem search --jql 'parent = HCON-34900' --fields "key" --json | jq -r '.[].key'
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
- **Missing `JIRA_BASE_URL` / `JIRA_USERNAME` / `JIRA_API_TOKEN`** (only needed for a
  backlog pick) → tell the user to source their env, stop.
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
1. resolves board 987 → project HCON → active sprint,
2. finds a sprint item (board order, no subtask/epic),
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

**Consistency:** Command flags match the validated `acli` invocations (`assign --assignee @me`, `transition --status "In Progress" --yes`, `workitem search --jql ... --json`); REST path `/rest/agile/1.0/sprint/<id>/issue` consistent across Task 4. Project-key extraction (`list-projects`) and sprint extraction (`list-sprints`) consistent between Task 2 and later usage.

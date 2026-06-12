# jira-next-item skill — design

Date: 2026-06-11
Status: approved (pre-implementation)

## Purpose

A user-invocable skill that starts the next work item from a Jira board. It finds
the highest-priority (board order, not the priority field) item that is unassigned
and in a To Do status, preferring the active sprint and falling back to the backlog.
When it grabs a backlog item it confirms before pulling it into the sprint, then
assigns the item (and its subtasks) to the user, moves it to In Progress, and hands
off to the brainstorming skill seeded with the ticket's details.

## Shape & invocation

- Location: `~/.claude/skills/jira-next-item/SKILL.md` (instructions-only; no helper
  scripts — matches existing personal skills like `daily-standup`, `morning-routine`).
- **User-invocable only** (`/jira-next-item`). The frontmatter `description` is written
  factually and explicitly so it does not eagerly auto-trigger on unrelated phrasing.
- Optional argument: board **name or ID**.
  - Numeric arg → use directly as board ID.
  - Text arg → `acli jira board search --name "<arg>" --json`; exact name match wins.
    Multiple matches or none → list candidates and ask the user which.
  - No arg → default to hardcoded board **`987`** (project **`HCON`**).
- The active sprint ID is **never** hardcoded — always resolved live.

## Dependencies / environment

- `acli` (authenticated; see `acli` skill) for all read/assign/transition ops.
- `curl` + `jq` for the Agile REST sprint-add call.
- Env vars (already set on this machine): `JIRA_BASE_URL`, `JIRA_USERNAME`,
  `JIRA_API_TOKEN`. `JIRA_API_TOKEN` holds a **1Password secret reference** (`op://...`),
  not the literal token — resolve it with `op read "$JIRA_API_TOKEN"` before use. REST
  auth = HTTP basic `"$JIRA_USERNAME:$(op read "$JIRA_API_TOKEN")"`. Requires `op` CLI
  authenticated (see `1password` skill).

## Selection logic

1. Resolve the board's project key: `acli jira board view --id <board> --json`.
2. Resolve the active sprint: `acli jira board list-sprints --id <board> --state active --json`.
3. **Sprint pass** — if an active sprint exists, query:
   ```
   sprint = <sprintId> AND assignee is EMPTY AND statusCategory = "To Do"
     AND issuetype not in subTaskIssueTypes() AND issuetype != Epic
     ORDER BY Rank ASC
   ```
   First result = the next item. No sprint-add needed (already in sprint).
4. **Backlog fallback** — only if the sprint pass returns nothing (or no active sprint):
   ```
   project = <KEY> AND sprint is EMPTY AND assignee is EMPTY
     AND statusCategory = "To Do" AND issuetype not in subTaskIssueTypes()
     AND issuetype != Epic ORDER BY Rank ASC
   ```
   First result = the next item; this path triggers the sprint-add confirm flow.
5. Nothing in either pass → report "no startable items" and stop.

Notes:
- `ORDER BY Rank ASC` = board/backlog order = priority (per requirement, not the
  priority field).
- `subTaskIssueTypes()` excludes orphan subtasks; `issuetype != Epic` excludes epics.
  Result set is real work items (Story / Task / Bug level) only.
- Use `--fields "key,summary,status,issuetype" --json --limit 1` for the picks.

## Start actions (after an item is selected)

1. **Backlog item only:** show the item (key, summary, type) and confirm it's
   acceptable to pull into the active sprint. On **no** → stop (nothing mutated).
   On **yes** → add via REST (resolve the 1Password token first):
   ```bash
   TOKEN=$(op read "$JIRA_API_TOKEN")
   curl -sS -w '%{http_code}' -u "$JIRA_USERNAME:$TOKEN" \
     -X POST -H 'Content-Type: application/json' \
     --data '{"issues":["<KEY>"]}' \
     "$JIRA_BASE_URL/rest/agile/1.0/sprint/<sprintId>/issue"
   ```
   Non-2xx → report status + body and **stop before any assignment** (no half-start).
2. Assign **the selected item** to the user: `acli jira workitem assign --key <KEY> --assignee @me`.
3. Transition **the selected item** to In Progress:
   `acli jira workitem transition --key <KEY> --status "In Progress" --yes`.
4. Assign **all of its subtasks** to the user: search `parent = <KEY>`
   (with `--fields "key,summary"` — `--fields "key"` alone makes acli return null rows) →
   `acli jira workitem assign --key <SUB> --assignee @me` for each. None → skip.
5. Fetch full ticket details once: `acli jira workitem view <KEY> --json`
   (summary, description, subtasks, comments). Then invoke `superpowers:brainstorming`,
   explicitly framed as **"working on Jira issue <KEY>"**, passing:
   - the ticket key `<KEY>` (so brainstorming can re-query attachments, comments,
     links if the seed isn't enough),
   - the summary and description,
   - the subtask list.

## Error / edge cases

- Board name no match / multiple matches → list candidates, ask which.
- No active sprint → state it, go straight to the backlog pass.
- REST sprint-add fails (non-2xx) → report status + body, stop before assigning.
- Any of `JIRA_BASE_URL` / `JIRA_USERNAME` / `JIRA_API_TOKEN` unset → tell the user to
  source their env and stop.
- Selected item has no subtasks → skip step 4.

## Authoring conventions (per skill-creator)

- **Frontmatter:** `name: jira-next-item`. The `description` is factual and scoped,
  not eager — it states what the skill does and that it's explicitly invoked, without
  broad keyword bait (skill-creator's default "make descriptions pushy" advice is
  deliberately inverted here because this skill is user-invocable only).
- **Writing style:** imperative steps; explain the *why* (e.g. that `ORDER BY Rank`
  reflects board order = priority, the requirement) rather than terse ALL-CAPS MUSTs.
- **Structure:** a single `SKILL.md`, comfortably under 500 lines, no bundled scripts.
  The REST sprint-add `curl` stays inline in the markdown (skill-creator rule #4 would
  nudge it into `scripts/`, but inline keeps it transparent and consistent with the
  other instruction-only personal skills like `daily-standup`).
- **Skipped:** evals, the description-optimization loop, and packaging — not needed
  for a single-user invoke-only workflow skill.

## Out of scope

- Re-ordering / re-ranking the board.
- Handling multiple boards in one invocation.
- Creating tickets, sprints, or estimates.
- Picking items that are assigned or already past To Do.

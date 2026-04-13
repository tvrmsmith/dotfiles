---
name: daily-standup
description: Use when preparing a daily standup report, summarizing yesterday's work, or reviewing what was accomplished. Triggers on: standup, stand-up, daily report, what did I do yesterday, EOD summary, daily sync.
---

# Daily Standup Report

Generates a standup report by gathering activity from multiple sources for the previous workday (Friday if today is Monday).

## Determine the Report Date

```bash
# If today is Monday, report on Friday. Otherwise report on yesterday.
if [ "$(date +%u)" -eq 1 ]; then
  REPORT_DATE=$(date -v-3d +%Y-%m-%d)
else
  REPORT_DATE=$(date -v-1d +%Y-%m-%d)
fi
```

## Data Sources

Gather from ALL sources in parallel, then synthesize.

### 1. Git Commits

Scan all repos under `~/dev/wellsky` for commits by the user on the report date:

```bash
# Find all git repos and check for commits
for repo in ~/dev/wellsky/*/; do
  if [ -d "$repo/.git" ]; then
    commits=$(git -C "$repo" log --oneline --after="$REPORT_DATE 00:00" --before="$REPORT_DATE 23:59" --author="trevor" 2>/dev/null)
    if [ -n "$commits" ]; then
      echo "## $(basename "$repo")"
      echo "$commits"
    fi
  fi
done
```

Also check for commits in the current working directory if it's not under `~/dev/wellsky`.

### 2. Claude Code Sessions

Search conversation history for sessions from the report date:

```bash
# Search history.jsonl for activity on the report date
grep "$REPORT_DATE" ~/.claude/history.jsonl | jq -r '.display' 2>/dev/null | head -30
```

Also check session JSONL files in `~/.claude/projects/` for sessions with timestamps matching the report date. Look at the user messages to understand what tasks were worked on.

### 3. JIRA Ticket Updates

Query for tickets assigned to the user that were updated on the report date:

```bash
# Tickets updated on the report date
acli jira workitem search \
  --jql "assignee = currentUser() AND updated >= '$REPORT_DATE' AND updated < '$REPORT_DATE' + 1d" \
  --fields "key,summary,status" \
  --json

# Also check for status transitions
acli jira workitem search \
  --jql "assignee = currentUser() AND status changed ON '$REPORT_DATE'" \
  --fields "key,summary,status" \
  --json
```

### 4. Confluence Changes

Use the Atlassian MCP tools to find Confluence pages the user contributed to on the report date.

**Search for recent contributions:**
```
searchConfluenceUsingCql(
  cloudId="...",
  cql="contributor = currentUser() AND lastModified >= '$REPORT_DATE' AND lastModified < '$NEXT_DAY'"
)
```

**If CQL contributor search isn't supported, fall back to cross-system search:**
```
search(
  cloudId="...",
  query="[user's name or known project terms]"
)
```
Then filter results by date.

**Fetch full page details for relevant hits:**
```
getConfluencePage(
  cloudId="...",
  pageId="[page ID from search results]",
  contentFormat="markdown"
)
```

Check version history to confirm the user's edits vs. other contributors.

## Output Format

Present the report in this structure:

```markdown
# Standup Report — [Report Date]

## What I worked on
- [Grouped by theme/ticket, not by data source]
- [Include ticket keys as PROJ-123 format]
- [Reference specific commits where helpful]

## Ticket Status Changes
- PROJ-123: In Progress → In Review
- PROJ-456: Open → In Progress

## Notes
- [Any blockers, carryover items, or context worth mentioning]
```

## Guidelines

- **Group by theme**, not by data source — the reader cares about what you accomplished, not where the data came from
- **Be concise** — standup reports should be scannable in 30 seconds
- **Highlight status changes** — these are the most useful signal for the team
- **Flag carryover** — if something from yesterday isn't done, note it
- If a data source is unavailable (auth issues, missing directory), note it briefly and continue with available sources

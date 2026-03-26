---
name: jira
description: Use when interacting with JIRA tickets, work items, sprints, or backlogs. Triggers on: jira, ticket, work item, acli, sprint, backlog, issue tracking, create ticket, transition status.
---

# JIRA with Atlassian CLI

Use `acli jira` for all JIRA operations. Do not use web interfaces or APIs directly.

## Quick Reference

| Operation | Command |
|-----------|---------|
| View | `acli jira workitem view KEY-123` |
| View (JSON) | `acli jira workitem view KEY-123 --json` |
| View (browser) | `acli jira workitem view KEY-123 --web` |
| View (fields) | `acli jira workitem view KEY-123 --fields summary,comment,assignee` |
| Search | `acli jira workitem search --jql "project = TEAM AND status = 'In Progress'"` |
| Search (paginate) | `acli jira workitem search --jql "project = TEAM" --paginate` |
| Search (CSV) | `acli jira workitem search --jql "..." --csv` |
| Search (JSON) | `acli jira workitem search --jql "..." --json --limit 50` |
| Search (fields) | `acli jira workitem search --jql "..." --fields "key,summary,status"` |

## Create Work Items

```bash
# Basic
acli jira workitem create --summary "New Task" --project "TEAM" --type "Task"

# Full details
acli jira workitem create \
  --summary "Bug fix needed" \
  --project "PROJ" \
  --type "Bug" \
  --assignee "user@example.com" \
  --label "bug,urgent"

# From file or JSON
acli jira workitem create --from-file "description.txt" --project "PROJ" --type "Story"
acli jira workitem create --from-json "workitem.json"
```

## Transition, Assign, Edit

```bash
# Transition status
acli jira workitem transition --key "KEY-1,KEY-2" --status "Done"
acli jira workitem transition --jql "project = TEAM AND assignee = currentUser()" --status "In Progress"
acli jira workitem transition --key "KEY-123" --status "Done" --yes

# Assign
acli jira workitem assign --key "KEY-123" --assignee "user@example.com"
acli jira workitem assign --key "KEY-123" --assignee "@me"

# Edit summary or labels
acli jira workitem edit --key KEY-123 --summary "Updated summary"
acli jira workitem clone KEY-123
```

## Descriptions

The `--description` flag accepts **plain text only** — Jira wiki markup (h2., *, {{code}}) is NOT supported and will render as literal text.

For formatted descriptions, use `--description-file` with an **Atlassian Document Format (ADF)** JSON file:

```bash
# Plain text (no formatting)
acli jira workitem edit --key KEY-123 --description "Simple plain text description"

# Formatted via ADF JSON file
acli jira workitem edit --key KEY-123 --description-file /tmp/description.json
```

ADF JSON structure:
```json
{
  "type": "doc",
  "version": 1,
  "content": [
    {
      "type": "heading",
      "attrs": { "level": 2 },
      "content": [{ "type": "text", "text": "Section Title" }]
    },
    {
      "type": "paragraph",
      "content": [
        { "type": "text", "text": "Regular text and " },
        { "type": "text", "text": "code", "marks": [{ "type": "code" }] }
      ]
    },
    { "type": "rule" },
    {
      "type": "bulletList",
      "content": [
        {
          "type": "listItem",
          "content": [{
            "type": "paragraph",
            "content": [{ "type": "text", "text": "Bullet item" }]
          }]
        }
      ]
    },
    {
      "type": "paragraph",
      "content": [{
        "type": "text",
        "text": "Link text",
        "marks": [{ "type": "link", "attrs": { "href": "https://example.com" } }]
      }]
    }
  ]
}
```

ADF marks: `code`, `strong`, `em`, `link` (with `attrs.href`), `strike`, `underline`.
ADF blocks: `paragraph`, `heading` (with `attrs.level`), `bulletList`, `orderedList`, `listItem`, `rule`, `codeBlock`, `blockquote`.

## Custom Fields

The CLI only exposes standard fields (summary, description, assignee, labels, type). It does **not** support custom fields (e.g. "Success Criteria") via flags. Workaround: include custom field content as a section in the description.

## Comments

```bash
acli jira workitem comment create KEY-123 --message "Your comment here"
acli jira workitem comment list KEY-123
acli jira workitem comment update KEY-123 COMMENT-ID --message "Updated comment"
```

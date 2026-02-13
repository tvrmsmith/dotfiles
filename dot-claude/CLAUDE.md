# Global Claude Instructions

## Git Configuration

### Personal Repository SSH Setup

**For repositories under `tvrmsmith/*` (personal repos):**
- Must use `github-personal` SSH host alias instead of `github.com`
- SSH keys are managed by 1Password (see `~/.ssh/config` and `~/.ssh/1Password/config`)

**If you get "Permission denied" when pushing to a tvrmsmith/* repository:**
```bash
# Check current remote URL
git remote -v

# If it shows github.com instead of github-personal, fix it:
git remote set-url origin git@github-personal:tvrmsmith/<repo-name>.git

# Verify and push
git remote -v
git push -u origin <branch-name>
```

**For work repositories (non-tvrmsmith):**
- Use `github.com` directly (default behavior)

## Tool Preferences

### Search Tools

**Prefer ripgrep (`rg`) over `grep`:**
- When searching for patterns in files, use `rg` instead of `grep`
- Ripgrep is faster, has better defaults, and respects `.gitignore`
- Use the Grep tool which is built on ripgrep, or use `rg` via Bash when needed

### JIRA Interactions

**Use Atlassian CLI (`acli`) for JIRA operations:**
- When interacting with JIRA tickets, use the `acli jira` command instead of web interfaces or APIs
- The Atlassian CLI provides a consistent, scriptable interface for JIRA work items

**View work items:**
```bash
# View a specific work item
acli jira workitem view KEY-123

# View with specific fields
acli jira workitem view KEY-123 --fields summary,comment,assignee

# Open in web browser
acli jira workitem view KEY-123 --web

# Get JSON output
acli jira workitem view KEY-123 --json
```

**Search for work items:**
```bash
# Search with JQL query
acli jira workitem search --jql "project = TEAM AND status = 'In Progress'"

# Search and get all results with pagination
acli jira workitem search --jql "project = TEAM" --paginate

# Search with custom fields
acli jira workitem search --jql "assignee = currentUser()" --fields "key,summary,status"

# Search and output as CSV or JSON
acli jira workitem search --jql "project = TEAM" --csv
acli jira workitem search --jql "project = TEAM" --json --limit 50
```

**Create work items:**
```bash
# Create with basic details
acli jira workitem create --summary "New Task" --project "TEAM" --type "Task"

# Create with full details
acli jira workitem create \
  --summary "Bug fix needed" \
  --project "PROJ" \
  --type "Bug" \
  --assignee "user@example.com" \
  --label "bug,urgent"

# Create with description from file
acli jira workitem create \
  --from-file "description.txt" \
  --project "PROJ" \
  --type "Story"

# Create from JSON definition
acli jira workitem create --from-json "workitem.json"
```

**Transition work items (change status):**
```bash
# Transition single or multiple work items
acli jira workitem transition --key "KEY-1,KEY-2" --status "Done"

# Transition via JQL query
acli jira workitem transition --jql "project = TEAM AND assignee = currentUser()" --status "In Progress"

# Transition without confirmation prompt
acli jira workitem transition --key "KEY-123" --status "Done" --yes
```

**Comment on work items:**
```bash
# Create a comment
acli jira workitem comment create KEY-123 --message "Your comment here"

# List comments for a work item
acli jira workitem comment list KEY-123

# Update a comment
acli jira workitem comment update KEY-123 COMMENT-ID --message "Updated comment"
```

**Other operations:**
```bash
# Assign work item
acli jira workitem assign --key "KEY-123" --assignee "user@example.com"

# Assign to self
acli jira workitem assign --key "KEY-123" --assignee "@me"

# Edit work item
acli jira workitem edit KEY-123 --summary "Updated summary"

# Clone work item
acli jira workitem clone KEY-123
```
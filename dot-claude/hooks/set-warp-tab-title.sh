#!/bin/bash
# Write Claude session name to file for shell to read
# Runs on SessionStart hook - the actual title update happens in shell prompt

# Read hook data from stdin (Claude Code passes JSON with session info)
HOOK_DATA=$(cat)

# Extract session_id from JSON
SESSION_ID=$(echo "$HOOK_DATA" | jq -r '.session_id // empty' 2>/dev/null)

# Extract cwd from JSON (fallback to pwd)
CWD=$(echo "$HOOK_DATA" | jq -r '.cwd // empty' 2>/dev/null)
if [ -z "$CWD" ]; then
    CWD="$(pwd)"
fi

# Default title to project name
PROJECT_NAME="$(basename "$CWD")"
TITLE="$PROJECT_NAME"

# If we have a session ID, try to get custom title
if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "null" ]; then
    # Find .claude directory (could be in home or current directory)
    CLAUDE_DIR=""
    if [ -d "$HOME/.claude" ]; then
        CLAUDE_DIR="$HOME/.claude"
    elif [ -d ".claude" ]; then
        CLAUDE_DIR=".claude"
    fi

    if [ -n "$CLAUDE_DIR" ]; then
        # Find session file by ID (search all project directories)
        SESSION_FILE=$(find "$CLAUDE_DIR/projects" -name "${SESSION_ID}.jsonl" 2>/dev/null | head -1)

        if [ -n "$SESSION_FILE" ] && [ -f "$SESSION_FILE" ]; then
            # Try to extract custom title from session file
            CUSTOM_TITLE=$(jq -r 'select(.type == "custom-title") | .customTitle' "$SESSION_FILE" 2>/dev/null | tail -1)

            if [ -n "$CUSTOM_TITLE" ] && [ "$CUSTOM_TITLE" != "null" ]; then
                TITLE="$CUSTOM_TITLE"
            fi
        fi
    fi
fi

# Write session name to cache file in the project directory
# The shell prompt will read this file and update the tab title
CACHE_DIR="$CWD/.claude"
mkdir -p "$CACHE_DIR"
echo "$TITLE" > "$CACHE_DIR/session-name"

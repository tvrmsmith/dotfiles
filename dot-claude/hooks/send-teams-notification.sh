#!/bin/bash
# Teams notification script for Claude Code hooks
# Sends rich notifications with context about Claude's work

EVENT_TYPE="$1"  # "notification" or "stop"
WEBHOOK_URL="${TEAMS_PERSONAL_NOTIFICATIONS_WEBHOOK_URL}"

if [ -z "$WEBHOOK_URL" ]; then
    echo "Warning: TEAMS_PERSONAL_NOTIFICATIONS_WEBHOOK_URL not set" >&2
    exit 0
fi

# Get current directory and project info
WORKING_DIR="$(pwd)"
PROJECT_NAME="$(basename "$WORKING_DIR")"

# Try to get git branch if in a git repo
GIT_BRANCH=""
if git rev-parse --git-dir > /dev/null 2>&1; then
    GIT_BRANCH="$(git branch --show-current 2>/dev/null)"
fi

# Build context message
CONTEXT="📁 **Project:** \`$PROJECT_NAME\`  \n📂 **Path:** \`$WORKING_DIR\`"
if [ -n "$GIT_BRANCH" ]; then
    CONTEXT="$CONTEXT  \n🌿 **Branch:** \`$GIT_BRANCH\`"
fi

# Build message based on event type
if [ "$EVENT_TYPE" = "notification" ]; then
    TITLE="🔔 Claude Code - Input Needed"
    MESSAGE="Claude needs your input to continue.  \n\n$CONTEXT  \n\n⏰ $(date '+%I:%M %p')"
else
    TITLE="✅ Claude Code - Task Complete"
    MESSAGE="Claude has finished working and is ready.  \n\n$CONTEXT  \n\n⏰ $(date '+%I:%M %p')"
fi

# Send to Teams via Power Automate
# Using Adaptive Card format required by Teams
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"

# Build the facts array for the Adaptive Card
FACTS="[
    {\"title\": \"Project:\", \"value\": \"$PROJECT_NAME\"},
    {\"title\": \"Directory:\", \"value\": \"$WORKING_DIR\"}"

if [ -n "$GIT_BRANCH" ]; then
    FACTS="$FACTS,
    {\"title\": \"Branch:\", \"value\": \"$GIT_BRANCH\"}"
fi

FACTS="$FACTS,
    {\"title\": \"Time:\", \"value\": \"$TIMESTAMP\"}
]"

# Determine emoji and message based on event type
if [ "$EVENT_TYPE" = "notification" ]; then
    EMOJI="🔔"
    MESSAGE_TEXT="Claude needs your input to continue"
else
    EMOJI="✅"
    MESSAGE_TEXT="Claude has finished working"
fi

curl -X POST "$WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "{
        \"type\": \"AdaptiveCard\",
        \"\$schema\": \"http://adaptivecards.io/schemas/adaptive-card.json\",
        \"version\": \"1.4\",
        \"body\": [
            {
                \"type\": \"TextBlock\",
                \"text\": \"$EMOJI Claude Code Notification\",
                \"weight\": \"Bolder\",
                \"size\": \"Large\"
            },
            {
                \"type\": \"TextBlock\",
                \"text\": \"$MESSAGE_TEXT\",
                \"size\": \"Medium\",
                \"weight\": \"Bolder\",
                \"wrap\": true
            },
            {
                \"type\": \"FactSet\",
                \"facts\": $FACTS
            }
        ]
    }" \
    2>/dev/null || true

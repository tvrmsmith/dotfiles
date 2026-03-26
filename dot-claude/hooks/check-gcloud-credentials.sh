#!/bin/bash

# Check if gcloud application_default_credentials.json is over 6 hours old
# If so, refresh it by running gcloud auth application-default login

CREDENTIALS_FILE="$HOME/.config/gcloud/application_default_credentials.json"
MAX_AGE_SECONDS=$((6 * 60 * 60))  # 6 hours in seconds

# Check if the credentials file exists
if [ ! -f "$CREDENTIALS_FILE" ]; then
    echo "Warning: gcloud credentials file not found at $CREDENTIALS_FILE"
    echo "Running: gcloud auth application-default login"
    gcloud auth application-default login
    exit 0
fi

# Get the file's modification time in seconds since epoch
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    FILE_MTIME=$(stat -f %m "$CREDENTIALS_FILE")
else
    # Linux
    FILE_MTIME=$(stat -c %Y "$CREDENTIALS_FILE")
fi

# Get current time in seconds since epoch
CURRENT_TIME=$(date +%s)

# Calculate age in seconds
AGE_SECONDS=$((CURRENT_TIME - FILE_MTIME))

# Check if file is older than 6 hours
if [ $AGE_SECONDS -gt $MAX_AGE_SECONDS ]; then
    HOURS=$((AGE_SECONDS / 3600))
    echo "gcloud credentials are $HOURS hours old (max: 6 hours)"
    echo "Running: gcloud auth application-default login"
    gcloud auth application-default login
else
    HOURS=$((AGE_SECONDS / 3600))
    MINUTES=$(((AGE_SECONDS % 3600) / 60))
    echo "gcloud credentials are fresh ($HOURS hours, $MINUTES minutes old)"
fi

exit 0

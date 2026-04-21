#!/bin/bash
# Generate an SSH commit-signing key and upload it to both GitHub accounts.
# Replaces any existing key with the same title on each account.
# Requires github_token and github_token_personal via --mount=type=secret.
set -euo pipefail

KEY_TITLE="sandbox-signing-key"
KEY_PATH="$HOME/.ssh/sandbox_signing"
GH_API="https://api.github.com"

: "${GIT_USER_NAME:?GIT_USER_NAME is required}"
: "${GIT_USER_EMAIL:?GIT_USER_EMAIL is required}"

GITHUB_TOKEN="$(cat /run/secrets/github_token)"
GITHUB_TOKEN_PERSONAL="$(cat /run/secrets/github_token_personal)"

# Rotate signing key on a GitHub account: delete old, upload new
_upload_signing_key() {
  local token="$1" label="$2"

  # Delete existing sandbox signing keys
  local existing_ids
  existing_ids=$(curl -sf -H "Authorization: token $token" \
    "$GH_API/user/ssh_signing_keys?per_page=100" \
    | grep -B1 "\"$KEY_TITLE\"" | grep '"id"' | grep -o '[0-9]*' || true)

  for id in $existing_ids; do
    curl -sf -X DELETE -H "Authorization: token $token" \
      "$GH_API/user/ssh_signing_keys/$id"
    echo "Deleted old signing key $id ($label)"
  done

  # Upload public key
  local pub_key
  pub_key=$(cat "${KEY_PATH}.pub")
  curl -sf -X POST -H "Authorization: token $token" \
    -H "Content-Type: application/json" \
    -d "{\"title\":\"$KEY_TITLE\",\"key\":\"$pub_key\"}" \
    "$GH_API/user/ssh_signing_keys" > /dev/null
  echo "Uploaded signing key to GitHub ($label)"
}

# Generate new key
mkdir -p "$(dirname "$KEY_PATH")"
ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "$GIT_USER_NAME <$GIT_USER_EMAIL>" -q

# Upload to both accounts
_upload_signing_key "$GITHUB_TOKEN" "work"
_upload_signing_key "$GITHUB_TOKEN_PERSONAL" "personal"

# Write sandbox-specific git signing overrides to a local include file.
# Only signing config — identity (name/email) comes from repo-level config
# or dotfiles, so personal repo overrides are preserved.
cat > "$HOME/.gitconfig.sandbox" << EOF
[user]
	signingkey = $KEY_PATH
[gpg]
	format = ssh
[gpg \"ssh\"]
	allowedSignersFile = $HOME/.ssh/allowed_signers
[commit]
	gpgsign = true
[tag]
	gpgsign = true
EOF

# Create allowed_signers for verification
echo "$GIT_USER_EMAIL $(cat "${KEY_PATH}.pub")" > "$HOME/.ssh/allowed_signers"

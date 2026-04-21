#!/bin/bash
# Generate an SSH commit-signing key and upload it to GitHub.
# Replaces any existing key with the same title.
# Requires GITHUB_TOKEN via --mount=type=secret, GIT_USER_NAME and GIT_USER_EMAIL as env.
set -euo pipefail

KEY_TITLE="sandbox-signing-key"
KEY_PATH="$HOME/.ssh/sandbox_signing"
GH_API="https://api.github.com"

: "${GIT_USER_NAME:?GIT_USER_NAME is required}"
: "${GIT_USER_EMAIL:?GIT_USER_EMAIL is required}"

GITHUB_TOKEN="$(cat /run/secrets/github_token)"


# Delete existing sandbox signing keys
existing_ids=$(curl -sf -H "Authorization: token $GITHUB_TOKEN" \
  "$GH_API/user/ssh_signing_keys?per_page=100" \
  | grep -B1 "\"$KEY_TITLE\"" | grep '"id"' | grep -o '[0-9]*' || true)

for id in $existing_ids; do
  curl -sf -X DELETE -H "Authorization: token $GITHUB_TOKEN" \
    "$GH_API/user/ssh_signing_keys/$id"
  echo "Deleted old signing key $id"
done

# Generate new key
mkdir -p "$(dirname "$KEY_PATH")"
ssh-keygen -t ed25519 -f "$KEY_PATH" -N "" -C "$GIT_USER_NAME <$GIT_USER_EMAIL>" -q

# Upload public key
pub_key=$(cat "${KEY_PATH}.pub")
curl -sf -X POST -H "Authorization: token $GITHUB_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"$KEY_TITLE\",\"key\":\"$pub_key\"}" \
  "$GH_API/user/ssh_signing_keys" > /dev/null
echo "Uploaded signing key to GitHub"

# Write sandbox-specific git overrides to a local include file
# (avoids modifying the stow-symlinked ~/.gitconfig)
cat > "$HOME/.gitconfig.sandbox" << EOF
[user]
	name = $GIT_USER_NAME
	email = $GIT_USER_EMAIL
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

#!/bin/bash
# Generate SSH commit-signing keys and upload to GitHub accounts.
# Each account gets a unique key (GitHub enforces key uniqueness).
# Requires github_token and github_token_personal as Docker build secrets.
set -euo pipefail

# Per-image title so concurrent sandbox images don't delete each other's keys.
# Same-image rebuilds rotate idempotently because deletion is scoped to this title.
if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "usage: $0 <sandbox-id>" >&2
  exit 1
fi
KEY_TITLE="sandbox-signing-key:$1"
KEY_DIR="$HOME/.ssh"

: "${GIT_USER_NAME:?GIT_USER_NAME is required}"
: "${GIT_USER_EMAIL:?GIT_USER_EMAIL is required}"

setup_signing_key() {
  local token="$1" label="$2"
  local key_path="$KEY_DIR/sandbox_signing_${label}"

  # Generate key
  ssh-keygen -t ed25519 -f "$key_path" -N "" -C "$GIT_USER_NAME <$GIT_USER_EMAIL> ($label sandbox)" -q

  # Delete existing sandbox signing keys
  GH_TOKEN="$token" gh api /user/ssh_signing_keys --paginate --jq \
    ".[] | select(.title == \"$KEY_TITLE\") | .id" \
  | while read -r id; do
    GH_TOKEN="$token" gh api -X DELETE "/user/ssh_signing_keys/$id" --silent
    echo "Deleted old signing key $id ($label)" >&2
  done

  # Upload public key
  GH_TOKEN="$token" gh api /user/ssh_signing_keys \
    -f title="$KEY_TITLE" \
    -f key="$(cat "${key_path}.pub")" \
    --silent
  echo "Uploaded signing key to GitHub ($label)" >&2

  echo "$key_path"
}

mkdir -p "$KEY_DIR"

# Seed known_hosts with pinned host keys (github.com, etc.) so first
# `git clone git@...` doesn't prompt and abort on the SHA256 fingerprint check.
KNOWN_HOSTS_SRC="$HOME/dotfiles/dot-ssh/known_hosts.pinned"
if [ -f "$KNOWN_HOSTS_SRC" ]; then
  cat "$KNOWN_HOSTS_SRC" >> "$KEY_DIR/known_hosts"
  sort -u "$KEY_DIR/known_hosts" -o "$KEY_DIR/known_hosts"
  chmod 644 "$KEY_DIR/known_hosts"
else
  echo "WARN: $KNOWN_HOSTS_SRC missing; sandbox will prompt on first SSH host" >&2
fi

work_token="$(cat /run/secrets/github_token)"
personal_token="$(cat /run/secrets/github_token_personal)"

work_key=$(setup_signing_key "$work_token" "work")
personal_key=$(setup_signing_key "$personal_token" "personal")

# Write sandbox git signing config (work key as default)
cat > "$HOME/.gitconfig.sandbox" << EOF
[user]
	signingkey = $work_key
[gpg]
	format = ssh
[gpg "ssh"]
	program = /usr/bin/ssh-keygen
	allowedSignersFile = $KEY_DIR/allowed_signers
[commit]
	gpgsign = true
[tag]
	gpgsign = true
EOF

# Personal repos get their own signing key
cat > "$HOME/.gitconfig.sandbox-personal" << EOF
[user]
	signingkey = $personal_key
EOF

# Ensure sandbox config is included on every shell startup
# (sandbox runtime overwrites ~/.gitconfig after build)
cat >> "$HOME/.bashrc" << 'BASHEOF'

# Re-include dotfiles and sandbox git config if sandbox runtime overwrote ~/.gitconfig
if ! grep -q 'gitconfig.sandbox' "$HOME/.gitconfig" 2>/dev/null; then
  git config --global --add include.path "$HOME/dotfiles/dot-gitconfig"
  git config --global --add include.path "$HOME/.gitconfig.sandbox"
fi
BASHEOF

# Create allowed_signers for verification (both keys)
echo "$GIT_USER_EMAIL $(cat "${work_key}.pub")" > "$KEY_DIR/allowed_signers"
echo "$GIT_USER_EMAIL $(cat "${personal_key}.pub")" >> "$KEY_DIR/allowed_signers"

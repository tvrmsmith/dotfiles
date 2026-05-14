#!/usr/bin/env bash
set -euo pipefail

# Discover host paths from bind mounts (mirrored at their host paths).
HOST_HOME="" DEV_PERSONAL=""
for _base in /Users/* /home/*; do
  [ -d "$_base/dev/personal/dotfiles" ] && [ "$_base" != "$HOME" ] && {
    HOST_HOME="$_base"
    DEV_PERSONAL="$_base/dev/personal"
    break
  }
done
if [ -z "$HOST_HOME" ]; then
  echo "ERROR: could not discover host home from bind mounts" >&2
  exit 1
fi

# 1. gcloud ADC
if [ -d "$HOST_HOME/.config/gcloud" ]; then
  install -d -m 700 "$HOME/.config/gcloud"
  ln -sf "$HOST_HOME/.config/gcloud/application_default_credentials.json" \
    "$HOME/.config/gcloud/application_default_credentials.json"
fi

# 2. Claude plugins
if [ -d "$HOST_HOME/.claude/plugins" ]; then
  mkdir -p "$HOME/.claude"
  rm -rf "$HOME/.claude/plugins"
  ln -sfn "$HOST_HOME/.claude/plugins" "$HOME/.claude/plugins"
fi

# 3. omp fork (dangling if no host build — launcher shim handles fallback)
mkdir -p "$HOME/.cache"
ln -sfn "$HOST_HOME/.cache/dsbx-omp-fork" "$HOME/.omp-fork"

# 4. stow host dotfiles
DOTFILES_MOUNT="$DEV_PERSONAL/dotfiles"
if [ -d "$DOTFILES_MOUNT" ]; then
  cd "$DOTFILES_MOUNT"

  mkdir -p "$HOME/.claude"
  rm -f \
    "$HOME/.bashrc" \
    "$HOME/.gitconfig" \
    "$HOME/.claude/settings.json"

  ignore_args=(--ignore=extras)
  while IFS= read -r abs; do
    ignore_args+=(--ignore="$(basename "$abs")")
  done < <(find . -type l ! -path "./.git/*" -exec sh -c \
    'tgt=$(readlink "$1"); case "$tgt" in /*) echo "$1";; esac' _ {} \;)

  stow --no-folding --dotfiles -t "$HOME" "${ignore_args[@]}" .

  # When the dotfiles repo IS the workspace (RW), stow symlinks point into
  # the writable mount. Copy mutable files so sandbox tools don't modify the repo.
  if [ -w "$DOTFILES_MOUNT/dot-gitconfig" ]; then
    for f in .gitconfig .config/gh/hosts.yml .claude/settings.json; do
      [ -L "$HOME/$f" ] && cp --remove-destination "$(readlink -f "$HOME/$f")" "$HOME/$f"
    done
  fi
fi

# 5. SSH known_hosts merge (kit places known_hosts.pinned at ~/. ssh/)
if [ -f "$HOME/.ssh/known_hosts.pinned" ]; then
  install -d -m 700 "$HOME/.ssh"
  cat "$HOME/.ssh/known_hosts.pinned" >> "$HOME/.ssh/known_hosts"
  sort -u "$HOME/.ssh/known_hosts" -o "$HOME/.ssh/known_hosts"
  chmod 644 "$HOME/.ssh/known_hosts"
fi

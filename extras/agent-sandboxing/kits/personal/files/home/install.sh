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
  mkdir -p "$HOME/.claude/plugins"
  for entry in "$HOST_HOME/.claude/plugins"/*; do
    [ -e "$entry" ] || continue
    local_name="$(basename "$entry")"
    case "$local_name" in
      known_marketplaces.json|installed_plugins.json)
        sed "s|$HOST_HOME|$HOME|g" "$entry" > "$HOME/.claude/plugins/$local_name"
        ;;
      *)
        ln -sfn "$entry" "$HOME/.claude/plugins/$local_name"
        ;;
    esac
  done
fi

# 3. omp fork (dangling if no host build — launcher shim handles fallback)
mkdir -p "$HOME/.cache"
ln -sfn "$HOST_HOME/.cache/dsbx/omp-fork" "$HOME/.omp-fork"

# Copy dot-prefixed entries from source dir into $HOME, translating
# the "dot-" prefix to "." (e.g. dot-gitconfig → .gitconfig).
# Directories are rsync'd recursively; files are cp'd.
_copy_dotfiles() {
  local src="$1"
  for entry in "$src"/dot-*; do
    [ -e "$entry" ] || continue
    local target="$HOME/.${entry##*/dot-}"
    if [ -d "$entry" ]; then
      rsync -a "$entry/" "$target/"
    else
      cp "$entry" "$target"
    fi
  done
}

# 4. Install host dotfiles
DOTFILES_MOUNT="$DEV_PERSONAL/dotfiles"
if [ -d "$DOTFILES_MOUNT" ]; then
  mkdir -p "$HOME/.claude"
  rm -f \
    "$HOME/.bashrc" \
    "$HOME/.gitconfig" \
    "$HOME/.claude/settings.json"

  if [ -w "$DOTFILES_MOUNT/dot-gitconfig" ]; then
    # Dotfiles repo is the RW workspace — copy to avoid mutating the repo
    _copy_dotfiles "$DOTFILES_MOUNT"
  else
    # RO helper mount — symlink via stow so host changes propagate live
    stow --dotfiles -d "$DEV_PERSONAL" -t "$HOME" dotfiles
  fi

  # sbx's agent runtime overwrites ~/.claude/settings.json on launch.
  # Stash our copy and prepend a restore line to .bashrc so it runs
  # before the agent reads config.
  if [ -f "$HOME/.claude/settings.json" ]; then
    cp "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.dotfiles"
    echo '[ -f "$HOME/.claude/settings.json.dotfiles" ] && cp "$HOME/.claude/settings.json.dotfiles" "$HOME/.claude/settings.json"' \
      >> "$HOME/.bashrc"
  fi
fi

# 5. SSH known_hosts merge (kit places known_hosts.pinned at ~/. ssh/)
if [ -f "$HOME/.ssh/known_hosts.pinned" ]; then
  install -d -m 700 "$HOME/.ssh"
  cat "$HOME/.ssh/known_hosts.pinned" >> "$HOME/.ssh/known_hosts"
  sort -u "$HOME/.ssh/known_hosts" -o "$HOME/.ssh/known_hosts"
  chmod 644 "$HOME/.ssh/known_hosts"
fi

# 6. Claude session state persistence
# Discover sandbox state dir from bind mounts — the host-side
# $XDG_STATE_HOME/dsbx/sandboxes/<name>/ is mounted RW at its host path.
DSBX_STATE=""
if [ -n "$HOST_HOME" ]; then
  for _d in "$HOST_HOME/.local/state/dsbx/sandboxes"/*/; do
    [ -d "${_d}sessions" ] && { DSBX_STATE="${_d%/}"; break; }
  done
fi

if [ -n "$DSBX_STATE" ]; then
  mkdir -p "$HOME/.claude"
  for subdir in sessions plans projects; do
    [ -d "$DSBX_STATE/$subdir" ] && ln -sfn "$DSBX_STATE/$subdir" "$HOME/.claude/$subdir"
  done
  [ -f "$DSBX_STATE/history.jsonl" ] && \
    ln -sf "$DSBX_STATE/history.jsonl" "$HOME/.claude/history.jsonl"
fi

#!/usr/bin/env bash
# In-container helper invoked by `_dsbx_install_helper_links` (host-side, in
# 20-dsbx.zsh) once per sandbox-create. Idempotent.
#
# Inputs (env):
#   HOST_HOME      Host $HOME, used to resolve bind-mounted paths inside the
#                  container (the bind mount lands at the same path on both
#                  sides, so HOST_HOME doubles as the in-container path).
#   DEV_PERSONAL   Host $DEV_PERSONAL (e.g. /Users/<user>/dev/personal).
#
# Effects:
#   1. Symlink ~/.config/gcloud/application_default_credentials.json -> bind mount
#   2. Symlink ~/.claude/plugins -> bind mount
#   3. Symlink ~/.omp-fork -> $HOME/.cache/dsbx-omp-fork (built fork bind mount).
#      Stable in-container path so the omp launcher shim doesn't need to know
#      the host $HOME. Symlink is created unconditionally; the dangling case
#      (no host build yet) is handled by the shim's existence check.
#   4. stow host dotfiles into ~ with --no-folding so leaf files become symlinks
#      into the read-only bind mount; sandbox-baked files (.bashrc, .gitconfig,
#      .ssh/allowed_signers) and absolute-target symlinks are skipped via
#      --ignore. .claude/settings.json is intentionally allowed: claude's
#      first-run stub is removed first so the host config wins.
#   5. Append pinned SSH known_hosts so first git@github.com clone does not
#      prompt.
#
# The omp fork build itself runs from the host via `dsbx-omp-build` (in
# 20-dsbx.zsh). It writes to ~/.cache/dsbx-omp-fork/ on the host, which is
# bind-mounted RO into every dsbx-omp sandbox. Host edits go live in every
# running sandbox the moment dsbx-omp-build completes — no --recreate.
set -euo pipefail

: "${HOST_HOME:?HOST_HOME required}"
: "${DEV_PERSONAL:?DEV_PERSONAL required}"

# 1. gcloud ADC
if [ -d "$HOST_HOME/.config/gcloud" ]; then
  install -d -m 700 "$HOME/.config/gcloud"
  ln -sf "$HOST_HOME/.config/gcloud/application_default_credentials.json" \
    "$HOME/.config/gcloud/application_default_credentials.json"
fi

# 2. Claude plugins (live host dir, not a snapshot)
if [ -d "$HOST_HOME/.claude/plugins" ]; then
  # Plugin dir may pre-exist from earlier sandbox versions that copied it in.
  rm -rf "$HOME/.claude/plugins"
  ln -sfn "$HOST_HOME/.claude/plugins" "$HOME/.claude/plugins"
fi

# 3. omp fork (built tree, bind-mounted from host cache). Symlink unconditionally:
# the launcher shim probes ~/.omp-fork/packages/coding-agent/src/cli.ts and falls
# back to the published omp install if the symlink is dangling (no host build yet).
ln -sfn "$HOST_HOME/.cache/dsbx-omp-fork" "$HOME/.omp-fork"

# 4. stow host dotfiles
DOTFILES_MOUNT="$DEV_PERSONAL/dotfiles"
if [ -d "$DOTFILES_MOUNT" ]; then
  cd "$DOTFILES_MOUNT"

  # claude writes a 6-line stub at first run; remove it so stow can land the
  # full host settings.json as a leaf symlink.
  rm -f "$HOME/.claude/settings.json"

  # Sandbox-baked files owned by Dockerfile / setup-signing-key.sh. Stowing
  # over them would corrupt the in-container identity, so skip them.
  # The repo ships .stow-local-ignore at its root, which (per stow semantics)
  # takes precedence over ~/.stow-global-ignore. Sandbox-only ignores must go
  # through --ignore on the command line.
  ignores=(
    bashrc
    gitconfig
    allowed_signers
    sandbox
  )

  # Absolute-target symlinks point at host-only repos that are not bind-mounted
  # into the sandbox; stow refuses them as fatal conflicts (no --skip flag).
  # Discover dynamically so adding a new host-linked skill does not silently
  # break sandbox creation.
  while IFS= read -r abs; do
    ignores+=("$(basename "$abs")")
  done < <(find . -type l ! -path "./.git/*" -exec sh -c \
    'tgt=$(readlink "$1"); case "$tgt" in /*) echo "$1";; esac' _ {} \;)

  ignore_args=()
  for pat in "${ignores[@]}"; do ignore_args+=(--ignore="$pat"); done
  stow --no-folding --dotfiles -t "$HOME" "${ignore_args[@]}" .

  # 4. Pinned SSH known_hosts. ~/.ssh is sandbox-baked (signing keys), so we
  # append rather than symlink, then dedupe.
  if [ -f "$DOTFILES_MOUNT/dot-ssh/known_hosts.pinned" ]; then
    install -d -m 700 "$HOME/.ssh"
    cat "$DOTFILES_MOUNT/dot-ssh/known_hosts.pinned" >> "$HOME/.ssh/known_hosts"
    sort -u "$HOME/.ssh/known_hosts" -o "$HOME/.ssh/known_hosts"
    chmod 644 "$HOME/.ssh/known_hosts"
  fi
fi
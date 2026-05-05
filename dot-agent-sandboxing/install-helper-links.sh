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
#   4. stow host dotfiles into ~ with --no-folding so leaf files become
#      symlinks into the read-only bind mount. Base-image stub files
#      (~/.bashrc, ~/.gitconfig, ~/.claude/settings.json) are removed first
#      so stow can land the host versions; absolute-target symlinks are
#      skipped via --ignore. The dir `dot-claude/sandbox/` (Dockerfiles,
#      docker-compose.yml) is also ignored — it has no place in $HOME.
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

  # Base-image / first-run stubs that would conflict with stow. Remove them
  # so the host-stowed leaf wins. ~/.gitconfig.sandbox is image-baked and
  # included by the host ~/.gitconfig — leave it alone.
  rm -f \
    "$HOME/.bashrc" \
    "$HOME/.gitconfig" \
    "$HOME/.claude/settings.json"

  # `dot-claude/sandbox/` (Dockerfiles, docker-compose.yml) has no place in
  # $HOME. Absolute-target symlinks point at host-only repos that are not
  # bind-mounted into the sandbox; stow refuses them as fatal conflicts
  # (no --skip flag), so discover them dynamically — adding a new host-linked
  # skill must not silently break sandbox creation.
  ignore_args=(--ignore=sandbox)
  while IFS= read -r abs; do
    ignore_args+=(--ignore="$(basename "$abs")")
  done < <(find . -type l ! -path "./.git/*" -exec sh -c \
    'tgt=$(readlink "$1"); case "$tgt" in /*) echo "$1";; esac' _ {} \;)

  stow --no-folding --dotfiles -t "$HOME" "${ignore_args[@]}" .

  # 5. Pinned SSH known_hosts. ~/.ssh may be sandbox-baked, so we append rather
  # than symlink, then dedupe.
  if [ -f "$DOTFILES_MOUNT/dot-ssh/known_hosts.pinned" ]; then
    install -d -m 700 "$HOME/.ssh"
    cat "$DOTFILES_MOUNT/dot-ssh/known_hosts.pinned" >> "$HOME/.ssh/known_hosts"
    sort -u "$HOME/.ssh/known_hosts" -o "$HOME/.ssh/known_hosts"
    chmod 644 "$HOME/.ssh/known_hosts"
  fi
fi
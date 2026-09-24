load helpers/setup
setup() { _install_test_setup; }
teardown() { _install_test_teardown; }

@test "second install leaves the repo copy alone when stow folded the parent" {
  run_setup_dotfiles
  [ "$status" -eq 0 ]
  # With ~/.claude absent, stow folds it into one symlink to dot-claude/.
  [ -L "$FAKE_HOME/.claude" ]

  run_setup_dotfiles
  [ "$status" -eq 0 ]
  [ -f "$FAKE_REPO/$REL_SETTINGS" ]
  grep -qx "tracked $REL_SETTINGS" "$FAKE_REPO/$REL_SETTINGS"
}

@test "drift guard keeps a target symlinked somewhere else" {
  unfold_parents
  local target elsewhere
  target="$(home_target "$REL_SETTINGS")"
  elsewhere="$TMP/other-settings.json"
  echo 'someone elses file' > "$elsewhere"
  ln -sfn "$elsewhere" "$target"

  run_setup_dotfiles
  [ -L "$target" ]
  [ "$(readlink "$target")" = "$elsewhere" ]
}

@test "drift guard keeps a target whose contents differ" {
  unfold_parents
  local target
  target="$(home_target "$REL_SETTINGS")"
  echo 'live edits not in the repo' > "$target"

  run_setup_dotfiles
  [ ! -L "$target" ]
  grep -qx 'live edits not in the repo' "$target"
}

@test "drift guard keeps a target that is neither a file nor a symlink" {
  unfold_parents
  local target
  target="$(home_target "$REL_SETTINGS")"
  mkdir -p "$target/somedir"

  run_setup_dotfiles
  [ -d "$target" ]
  [ -d "$target/somedir" ]
}

@test "setup_dotfiles unfolds the two ~/.config dirs their own tools write into" {
  seed_config_dirs

  run_setup_dotfiles
  [ "$status" -eq 0 ]
  local d
  for d in gh 1Password; do
    [ -d "$FAKE_HOME/.config/$d" ]
    [ ! -L "$FAKE_HOME/.config/$d" ]
  done
}

@test "stow links gh's config.yml but never the hosts.yml gh rewrites" {
  seed_config_dirs

  run_setup_dotfiles
  [ "$status" -eq 0 ]
  [ -L "$FAKE_HOME/.config/gh/config.yml" ]
  [ ! -e "$FAKE_HOME/.config/gh/hosts.yml" ]
}

@test "stow links 1Password's ssh config but never its telemetry marker" {
  seed_config_dirs

  run_setup_dotfiles
  [ "$status" -eq 0 ]
  [ -e "$FAKE_HOME/.config/1Password/ssh/agent.toml" ]
  [ ! -e "$FAKE_HOME/.config/1Password/telemetry-enabled" ]
}

@test "the runtime ignores are inert unless install.sh pre-creates the dirs" {
  # The discriminator for the mkdir in setup_dotfiles: run the same stow
  # WITHOUT it and ~/.config becomes one folded symlink, so stow never descends,
  # neither nested pattern is consulted, and hosts.yml arrives after all.
  seed_config_dirs

  run env HOME="$FAKE_HOME" stow --dotfiles -d "$FAKE_REPO" -t "$FAKE_HOME" .
  [ "$status" -eq 0 ]
  [ -L "$FAKE_HOME/.config" ]
  [ -e "$FAKE_HOME/.config/gh/hosts.yml" ]
}

@test "gh's hosts.yml is not tracked, and is ignored so it cannot come back" {
  # gh rewrote it through the fold for 12 commits before this was noticed.
  run git -C "$REPO_ROOT" ls-files --error-unmatch dot-config/gh/hosts.yml
  [ "$status" -ne 0 ]
  run git -C "$REPO_ROOT" check-ignore -q dot-config/gh/hosts.yml
  [ "$status" -eq 0 ]
}

@test "aborted stow restores every reconciled target as a relative link" {
  unfold_parents
  local rel target
  for rel in "$REL_SETTINGS" "$REL_HOSTS" "$REL_TELEMETRY"; do
    cp "$FAKE_REPO/$rel" "$(home_target "$rel")"
  done
  stub_failing_stow

  run_setup_dotfiles
  [ "$status" -eq 1 ]
  [[ "$output" == *"stow aborted"* ]]
  for rel in "$REL_SETTINGS" "$REL_HOSTS" "$REL_TELEMETRY"; do
    target="$(home_target "$rel")"
    [ -L "$target" ]
    # Stow only recognises links spelled relative to the package.
    [[ "$(readlink "$target")" != /* ]]
    [ "$target" -ef "$FAKE_REPO/$rel" ]
  done
}

@test "aborted stow restores absolute links when python3 is missing" {
  unfold_parents
  local rel target
  for rel in "$REL_SETTINGS" "$REL_HOSTS" "$REL_TELEMETRY"; do
    cp "$FAKE_REPO/$rel" "$(home_target "$rel")"
  done
  stub_failing_stow
  drop_python3

  run_setup_dotfiles
  [ "$status" -eq 1 ]
  for rel in "$REL_SETTINGS" "$REL_HOSTS" "$REL_TELEMETRY"; do
    target="$(home_target "$rel")"
    [ -L "$target" ]
    [ "$(readlink "$target")" = "$FAKE_REPO/$rel" ]
    [ "$target" -ef "$FAKE_REPO/$rel" ]
  done
}

@test "installing into a HOME with no ~/.local writes nothing into the repo" {
  # Folded, ~/.local links to dot-local/, and link_slice_pipeline's slice-wave
  # link then lands inside the checkout as an untracked file.
  mkdir -p "$FAKE_REPO/dot-local/bin" "$FAKE_REPO/slice-pipeline/bin"
  printf '#!/bin/sh\n' > "$FAKE_REPO/dot-local/bin/gh"
  printf '#!/bin/sh\n' > "$FAKE_REPO/slice-pipeline/bin/slice-wave"

  run env HOME="$FAKE_HOME" PATH="$PATH" bash -c \
    "source '$INSTALL_SH' && SCRIPT_DIR='$FAKE_REPO' && setup_dotfiles && link_slice_pipeline"
  [ "$status" -eq 0 ]
  [ ! -L "$FAKE_HOME/.local" ]
  [ ! -e "$FAKE_REPO/dot-local/bin/slice-wave" ]
  [ "$FAKE_HOME/.local/bin/slice-wave" -ef "$FAKE_REPO/slice-pipeline/bin/slice-wave" ]
}

@test "an absolute symlink to the repo's own file is respelled relative, not a conflict" {
  # Hand-made links (ln -s with an absolute path) point at the right file but
  # stow only owns links spelled relative to the package, so it aborted the
  # whole install on them.
  local rel="dot-config/glow/beads.json" target
  mkdir -p "$FAKE_REPO/dot-config/glow" "$FAKE_HOME/.config/glow"
  echo 'style' > "$FAKE_REPO/$rel"
  target="$(home_target "$rel")"
  ln -s "$FAKE_REPO/$rel" "$target"

  run_setup_dotfiles
  [ "$status" -eq 0 ]
  [ -L "$target" ]
  [[ "$(readlink "$target")" != /* ]]
  [ "$target" -ef "$FAKE_REPO/$rel" ]
}

@test "a skill no-mistakes init writes through the ~/.claude fold leaves the repo clean" {
  # init writes ~/.claude/skills/no-mistakes; with ~/.claude folded into
  # dot-claude/, that lands in the checkout and used to dirty it.
  export GIT_CONFIG_GLOBAL=/dev/null
  cp "$REPO_ROOT/.gitignore" "$FAKE_REPO/.gitignore"
  git -C "$FAKE_REPO" init -q
  git -C "$FAKE_REPO" add -A
  git -C "$FAKE_REPO" -c user.name=t -c user.email=t@t commit -qm seed

  run_setup_dotfiles
  [ "$status" -eq 0 ]
  mkdir -p "$FAKE_HOME/.claude/skills/no-mistakes"
  echo 'skill from the binary' > "$FAKE_HOME/.claude/skills/no-mistakes/SKILL.md"
  [ -f "$FAKE_REPO/dot-claude/skills/no-mistakes/SKILL.md" ]

  run git -C "$FAKE_REPO" status --porcelain
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

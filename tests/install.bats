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

load helpers/setup
setup() { _mysbx_test_setup; }
teardown() { _mysbx_test_teardown; }

run_core() { zsh -c "source '$MYSBX_CORE'; _mysbx_load_config; $1"; }

@test "helper mounts include existing state dir, skip missing dirs" {
  local state="$TMP/state/box"
  mkdir -p "$state"
  run run_core "cd '$TMP' && _mysbx_helper_mounts '$state'"
  grep -qxF -- "$state" <<< "$output"
}

@test "helper mounts skip a candidate that contains cwd" {
  # dotfiles dir = DEV_PERSONAL/dotfiles; cwd inside it must be excluded
  local df="$DEV_PERSONAL/dotfiles"; mkdir -p "$df/sub"
  run run_core "cd '$df/sub' && _MYSBX_HELPER_DOTFILES_DIR='$df' _mysbx_helper_mounts '$TMP/state/box'"
  [[ "$output" != *"$df:ro"* ]]
}

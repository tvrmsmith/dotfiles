load helpers/setup
setup() { _mysbx_test_setup; }
teardown() { _mysbx_test_teardown; }

run_core() { zsh -c "source '$MYSBX_CORE'; _mysbx_load_config; $1"; }

@test "is_preset recognizes presets, rejects real agents" {
  run run_core '_mysbx_is_preset cc && _mysbx_is_preset ruby-cc && _mysbx_is_preset omp && echo ok'
  [ "$output" = ok ]
  run run_core '_mysbx_is_preset claude'
  [ "$status" -ne 0 ]
}

@test "preset_agent maps presets to real agents" {
  [ "$(run_core '_mysbx_preset_agent cc')" = claude ]
  [ "$(run_core '_mysbx_preset_agent ruby-cc')" = claude ]
  [ "$(run_core '_mysbx_preset_agent omp')" = omp ]
}

@test "preset_template only set for ruby-cc" {
  [ "$(run_core '_mysbx_preset_template cc')" = "" ]
  [ "$(run_core '_mysbx_preset_template ruby-cc')" = "claude-sandbox-ruby-2.6.10:latest" ]
  [ "$(run_core '_mysbx_preset_template omp')" = "" ]
}

@test "preset_kits omits atlassian under DEV_PERSONAL" {
  cd "$DEV_PERSONAL"
  run run_core "cd '$DEV_PERSONAL' && _mysbx_preset_kits cc"
  [[ "$output" != *atlassian* ]]
  [[ "$output" == *"/kits/personal"* ]]
}

@test "preset_kits includes atlassian off DEV_PERSONAL" {
  run run_core "cd '$TMP' && _mysbx_preset_kits cc"
  [[ "$output" == *"/kits/atlassian"* ]]
}

@test "name uses prefix + cwd basename" {
  run run_core "cd '$TMP' && _mysbx_name mysbx-cc"
  [ "$output" = "mysbx-cc-$(basename "$TMP")" ]
}

load helpers/setup
setup() { _mysbx_test_setup; }
teardown() { _mysbx_test_teardown; }

@test "unknown verb forwards verbatim to real sbx" {
  run zsh "$MYSBX" ls --json
  [ "$status" -eq 0 ]
  [ "$(sbx_argv)" = "$(printf 'ls\n--json')" ]
}

@test "no args forwards bare to real sbx" {
  run zsh "$MYSBX"
  [ "$status" -eq 0 ]
  [ "$(sbx_argv)" = "" ]
}

@test "self-reference guard aborts" {
  cp "$MYSBX" "$TMP/mysbx"; chmod +x "$TMP/mysbx"
  REAL_SBX="$TMP/mysbx" run zsh "$MYSBX" ls
  [ "$status" -ne 0 ]
  [[ "$output" == *"resolves to the wrapper itself"* ]]
}

@test "env overrides config default for DEV_PERSONAL" {
  run zsh -c "source '$MYSBX_CORE'; _mysbx_load_config; print \$DEV_PERSONAL"
  [ "$status" -eq 0 ]
  [ "$output" = "$DEV_PERSONAL" ]
}

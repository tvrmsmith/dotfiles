load helpers/setup
setup() { _mysbx_test_setup; }
teardown() { _mysbx_test_teardown; }

@test "exec resyncs secret then forwards verbatim" {
  ( cd "$TMP" && zsh "$MYSBX" exec mybox -- claude -p hi )
  local argv; argv="$(sbx_argv)"
  grep -qx exec <<<"$argv"
  grep -qx mybox <<<"$argv"
  grep -qx claude <<<"$argv"
  grep -qx github <<<"$argv"     # secret resynced via stub sbx
}

@test "exec still forwards when secret resync fails (sandbox exists)" {
  STUB_OP_RC=1 run zsh -c "cd '$TMP' && '$MYSBX' exec mybox -- claude"
  [ "$status" -eq 0 ]
  grep -qx exec "$STUB_SBX_LOG"
}

load helpers/setup
setup() {
  _mysbx_test_setup
  # _mysbx_launch's interactive run/exec must not block tests: stub sbx exits 0.
  SRC="source '$MYSBX_CORE'; source '$SBX_ROOT/20-mysbx.zsh'; _mysbx_load_config; _mysbx_resolve_real_sbx;"
}
teardown() { _mysbx_test_teardown; }

@test "interactive functions are defined after sourcing" {
  run zsh -c "$SRC functions mysbx-cc >/dev/null && functions mysbx-omp >/dev/null && echo ok"
  [ "$output" = ok ]
}

@test "launch creates when sandbox absent, then runs" {
  # stub ls returns empty -> not found -> create path taken
  STUB_SBX_LS_OUTPUT="" run zsh -c "$SRC cd '$TMP' && _mysbx_launch cc"
  [ "$status" -eq 0 ]
  grep -qx create "$STUB_SBX_LOG"
  grep -qx run "$STUB_SBX_LOG"
}

@test "launch skips create when sandbox present" {
  local name="mysbx-cc-$(basename "$TMP")"
  STUB_SBX_LS_OUTPUT="$name" run zsh -c "$SRC cd '$TMP' && _mysbx_launch cc"
  [ "$status" -eq 0 ]
  ! grep -qx create "$STUB_SBX_LOG"
  grep -qx run "$STUB_SBX_LOG"
}

@test "launch with -p uses exec path with prompt" {
  STUB_SBX_LS_OUTPUT="" run zsh -c "$SRC cd '$TMP' && _mysbx_launch cc -p 'do a thing'"
  grep -qx exec "$STUB_SBX_LOG"
  grep -qx -- '-p' "$STUB_SBX_LOG"
}

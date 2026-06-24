load helpers/setup
setup() { _mysbx_test_setup; }
teardown() { _mysbx_test_teardown; }

run_core() { zsh -c "source '$MYSBX_CORE'; _mysbx_load_config; _mysbx_resolve_real_sbx; $1"; }

@test "github sync writes secret via stdin, never argv" {
  run run_core "cd '$TMP' && _mysbx_sync_github_secret box1"
  [ "$status" -eq 0 ]
  # stub sbx recorded a `secret set ... github` call
  grep -qx github "$STUB_SBX_LOG"
  grep -qx 'secret' "$STUB_SBX_LOG"
  # token value must NOT appear in recorded argv
  ! grep -q 'fake-token-for' "$STUB_SBX_LOG"
}

@test "github sync uses global scope off-personal" {
  run run_core "cd '$TMP' && _mysbx_sync_github_secret box1"
  grep -qx -- '-g' "$STUB_SBX_LOG"
}

@test "github sync uses per-sandbox scope under DEV_PERSONAL" {
  run run_core "cd '$DEV_PERSONAL' && _mysbx_sync_github_secret box1"
  grep -qx box1 "$STUB_SBX_LOG"
  ! grep -qx -- '-g' "$STUB_SBX_LOG"
}

@test "github sync is TTL-gated (second call skips sbx)" {
  run_core "cd '$TMP' && _mysbx_sync_github_secret box1"
  : > "$STUB_SBX_LOG"
  run run_core "cd '$TMP' && _mysbx_sync_github_secret box1"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_SBX_LOG" ]
}

@test "github sync hard-fails when op read fails" {
  STUB_OP_RC=1 run run_core "cd '$TMP' && _mysbx_sync_github_secret box1"
  [ "$status" -ne 0 ]
}

@test "sync_secrets skips atlassian under DEV_PERSONAL" {
  run run_core "cd '$DEV_PERSONAL' && _mysbx_sync_secrets box1"
  [ "$status" -eq 0 ]
  ! grep -qx atlassian "$STUB_SBX_LOG"
}

@test "sync_secrets includes atlassian off-personal" {
  run run_core "cd '$TMP' && _mysbx_sync_secrets box1"
  [ "$status" -eq 0 ]
  grep -qx atlassian "$STUB_SBX_LOG"
}

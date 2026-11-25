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

@test "github sync off-personal falls back on the personal account when no work account is set" {
  run run_core "cd '$TMP' && _mysbx_github_identity box1"
  [ "$output" = "$(printf 'my.1password.com\t%s\t-g' 'op://Private/GitHub Personal Access Token/token')" ]
}

@test "github sync off-personal reads the work token reference from GIT_TOKEN" {
  MYSBX_WORK_OP_ACCOUNT=work.1password.example GIT_TOKEN="op://WorkVault/GitHub PAT/token" \
    run run_core "cd '$TMP' && _mysbx_github_identity box1"
  [ "$output" = "$(printf 'work.1password.example\t%s\t-g' 'op://WorkVault/GitHub PAT/token')" ]
}

@test "github sync hard-fails off-personal when a work account is set without GIT_TOKEN" {
  MYSBX_WORK_OP_ACCOUNT=work.1password.example run run_core "cd '$TMP' && _mysbx_sync_github_secret box1"
  [ "$status" -ne 0 ]
  [[ "$output" == *GIT_TOKEN* ]]
  [ ! -s "$STUB_SBX_LOG" ]
}

@test "atlassian sync hard-fails when JIRA_TOKEN_REF is unset" {
  JIRA_USERNAME=you@example.com run run_core "cd '$TMP' && _mysbx_sync_atlassian_secret box1"
  [ "$status" -ne 0 ]
  [[ "$output" == *JIRA_TOKEN_REF* ]]
  [ ! -s "$STUB_SBX_LOG" ]
}

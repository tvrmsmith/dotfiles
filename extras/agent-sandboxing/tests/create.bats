load helpers/setup
setup() { _mysbx_test_setup; }
teardown() { _mysbx_test_teardown; }

@test "create with preset cc expands agent and injects kits + name" {
  ( cd "$TMP" && zsh "$MYSBX" create cc . )
  local argv; argv="$(sbx_argv)"
  grep -qx create <<<"$argv"
  grep -qx claude <<<"$argv"          # preset cc -> real agent claude
  ! grep -qx cc <<<"$argv"            # preset token not forwarded as agent
  grep -qx -- '--kit' <<<"$argv"
  grep -qx -- '--name' <<<"$argv"
  grep -q "mysbx-cc-$(basename "$TMP")" <<<"$argv"
}

@test "create with real agent claude forwards vanilla (no kits)" {
  ( cd "$TMP" && zsh "$MYSBX" create claude . )
  local argv; argv="$(sbx_argv)"
  grep -qx create <<<"$argv"
  grep -qx claude <<<"$argv"
  ! grep -qx -- '--kit' <<<"$argv"
}

@test "create with preset omp expands to omp agent" {
  ( cd "$TMP" && zsh "$MYSBX" create omp . )
  local argv; argv="$(sbx_argv)"
  grep -qx omp <<<"$argv"
  grep -qx -- '--kit' <<<"$argv"
}

@test "create ruby-cc passes template -t" {
  ( cd "$TMP" && zsh "$MYSBX" create ruby-cc . )
  local argv; argv="$(sbx_argv)"
  grep -qx -- '-t' <<<"$argv"
  grep -qx 'claude-sandbox-ruby-2.6.10:latest' <<<"$argv"
}

@test "create --clone reaches real sbx" {
  ( cd "$TMP" && zsh "$MYSBX" create cc --clone . )
  grep -qx -- '--clone' "$STUB_SBX_LOG"
}

@test "explicit --name overrides derived name" {
  ( cd "$TMP" && zsh "$MYSBX" create cc . --name custombox )
  grep -qx custombox "$STUB_SBX_LOG"
  ! grep -q "mysbx-cc-" "$STUB_SBX_LOG"
}

@test "create hard-fails when secret sync fails" {
  STUB_OP_RC=1 run zsh -c "cd '$TMP' && '$MYSBX' create cc ."
  [ "$status" -ne 0 ]
}

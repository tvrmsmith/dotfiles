# Shared bats setup. Sourced by each .bats file.
_mysbx_test_setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SBX_ROOT="$REPO_ROOT/extras/agent-sandboxing"
  export MYSBX_CORE="$SBX_ROOT/lib/mysbx-core.zsh"
  export MYSBX="$REPO_ROOT/dot-local/bin/mysbx"

  TMP="$(mktemp -d)"
  export STUB_SBX_LOG="$TMP/sbx.argv"
  : > "$STUB_SBX_LOG"
  export REAL_SBX="$SBX_ROOT/tests/helpers/stub-bin/sbx"

  # Isolated state/config so tests never touch real dirs.
  export XDG_STATE_HOME="$TMP/state"
  export XDG_CACHE_HOME="$TMP/cache"
  export HOME_STUB="$TMP/home"
  mkdir -p "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$HOME_STUB"

  # Stubs (op/docker) earlier on PATH; real zsh still found.
  export PATH="$SBX_ROOT/tests/helpers/stub-bin:$PATH"

  export DEV_PERSONAL="$TMP/dev/personal"
  mkdir -p "$DEV_PERSONAL"

  # Prevent zsh subshells from sourcing ~/.zshenv (which would clobber DEV_PERSONAL
  # and other env vars the tests set). Point ZDOTDIR at an empty temp dir.
  export ZDOTDIR="$TMP/zdotdir"
  mkdir -p "$ZDOTDIR"
}
_mysbx_test_teardown() { rm -rf "$TMP"; }
# Read recorded sbx argv as a newline string.
sbx_argv() { cat "$STUB_SBX_LOG"; }

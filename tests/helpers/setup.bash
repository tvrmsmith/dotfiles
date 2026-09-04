# Shared bats setup for install.sh. Sourced by each .bats file.
#
# setup_dotfiles reads $SCRIPT_DIR and $HOME and deletes files under both, so
# every test drives it against a scratch repo and a scratch home.
_install_test_setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export INSTALL_SH="$REPO_ROOT/install.sh"

  ORIG_PATH="$PATH"
  TMP="$(mktemp -d)"
  export FAKE_REPO="$TMP/repo"
  export FAKE_HOME="$TMP/home"
  mkdir -p "$FAKE_REPO" "$FAKE_HOME"

  # The three live-writer files install.sh reconciles, seeded in the repo.
  export REL_SETTINGS="dot-claude/settings.json"
  export REL_HOSTS="dot-config/gh/hosts.yml"
  export REL_TELEMETRY="dot-config/1Password/telemetry-enabled"
  local rel
  for rel in "$REL_SETTINGS" "$REL_HOSTS" "$REL_TELEMETRY"; do
    mkdir -p "$FAKE_REPO/$(dirname "$rel")"
    printf 'tracked %s\n' "$rel" > "$FAKE_REPO/$rel"
  done

  export STUB_BIN="$TMP/stub-bin"
  mkdir -p "$STUB_BIN"
}
# PATH is restored first: drop_python3 points it inside $TMP, which teardown
# is about to delete out from under itself.
_install_test_teardown() { PATH="$ORIG_PATH"; rm -rf "$TMP"; }

# $HOME path a dot- prefixed repo path stows to, mirroring install.sh.
home_target() { printf '%s\n' "$FAKE_HOME/.${1#dot-}"; }

# Make each live-writer target's parent a real directory, so stow links the
# files individually instead of folding the whole parent into one symlink.
unfold_parents() {
  mkdir -p "$FAKE_HOME/.claude" "$FAKE_HOME/.config/gh" "$FAKE_HOME/.config/1Password"
}

# Put a `stow` on PATH that fails, so the restore loop runs.
stub_failing_stow() {
  cat > "$STUB_BIN/stow" <<'SH'
#!/usr/bin/env bash
echo "stub stow: conflict" >&2
exit 1
SH
  chmod +x "$STUB_BIN/stow"
  export PATH="$STUB_BIN:$PATH"
}

# Shrink PATH to just the externals setup_dotfiles needs, leaving python3 off
# it. Call after stub_failing_stow so the stub still resolves.
drop_python3() {
  local tool src
  for tool in env bash mkdir readlink cmp rm ln; do
    src="$(command -v "$tool")" || return 1
    ln -sf "$src" "$STUB_BIN/$tool"
  done
  export PATH="$STUB_BIN"
  ! command -v python3 >/dev/null 2>&1
}

# Run setup_dotfiles in its own bash, since it exits on a stow failure.
run_setup_dotfiles() {
  run env HOME="$FAKE_HOME" PATH="$PATH" bash -c \
    "source '$INSTALL_SH' && SCRIPT_DIR='$FAKE_REPO' && setup_dotfiles"
}

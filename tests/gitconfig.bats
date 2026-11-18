load helpers/assert

# Reads dot-gitconfig directly, so the test covers the repo copy whether or not
# it is stowed, and no system config can mask a rule.
setup() {
  export GIT_CONFIG_GLOBAL="${BATS_TEST_DIRNAME}/../dot-gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  repo="$(mktemp -d)"
  git init -q "$repo"
  # A scratch HOME, so the machine-local includes (~/.gitconfig.ssh-push and the
  # rest) are whatever each test puts there, not what this machine has.
  export HOME="$(mktemp -d)"
}

teardown() { rm -rf "$repo" "$HOME"; }

# What install.sh does on a machine with 1Password's SSH agent.
with_ssh_push() {
  ln -s "${BATS_TEST_DIRNAME}/../extras/git/ssh-push.gitconfig" "$HOME/.gitconfig.ssh-push"
}

fetch_url() { git -C "$repo" remote get-url origin; }
push_url() { git -C "$repo" remote get-url --push origin; }

@test "a work ssh remote fetches over https and pushes over ssh" {
  with_ssh_push
  git -C "$repo" remote add origin git@github.com:o/r.git
  equals "$(fetch_url)" https://github.com/o/r.git
  equals "$(push_url)" git@github.com:o/r.git
}

@test "a github-personal remote fetches over https and keeps its ssh alias for push" {
  with_ssh_push
  git -C "$repo" remote add origin git@github-personal:o/r.git
  equals "$(fetch_url)" https://github.com/o/r.git
  equals "$(push_url)" git@github-personal:o/r.git
}

# Without the rewrite these would push with the read-only token and get a 403.
@test "an https remote pushes over ssh" {
  with_ssh_push
  git -C "$repo" remote add origin https://github.com/o/r.git
  equals "$(fetch_url)" https://github.com/o/r.git
  equals "$(push_url)" git@github.com:o/r.git
}

# No SSH agent to sign the push, so it rides https with the gh credential.
@test "without the ssh-push include every github remote pushes over https" {
  git -C "$repo" remote add origin git@github.com:o/r.git
  git -C "$repo" remote add personal git@github-personal:o/r.git
  git -C "$repo" remote add web https://github.com/o/r.git
  equals "$(push_url)" https://github.com/o/r.git
  equals "$(git -C "$repo" remote get-url --push personal)" https://github.com/o/r.git
  equals "$(git -C "$repo" remote get-url --push web)" https://github.com/o/r.git
}

@test "github https credentials come only from the gh shim" {
  helpers="$(git config --get-all credential.https://github.com.helper)"
  equals "$(printf '%s\n' "$helpers" | head -1)" ""
  contains "$(printf '%s\n' "$helpers" | tail -1)" '.local/bin/gh" auth git-credential'
}

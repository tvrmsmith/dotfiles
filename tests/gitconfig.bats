load helpers/assert

# Reads dot-gitconfig directly, so the test covers the repo copy whether or not
# it is stowed, and no system config can mask a rule.
setup() {
  export GIT_CONFIG_GLOBAL="${BATS_TEST_DIRNAME}/../dot-gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  repo="$(mktemp -d)"
  git init -q "$repo"
  # A scratch HOME, so the machine-local includes are whatever each test puts
  # there, not what this machine has.
  export HOME="$(mktemp -d)"
}

teardown() { rm -rf "$repo" "$HOME"; }

fetch_url() { git -C "$repo" remote get-url "${1:-origin}"; }
push_url() { git -C "$repo" remote get-url --push "${1:-origin}"; }

# One token per account and no SSH key, so every spelling of a GitHub remote
# fetches and pushes over https, where the gh shim answers with the owner's token.
@test "every github remote fetches and pushes over https" {
  git -C "$repo" remote add origin git@github.com:o/r.git
  git -C "$repo" remote add personal git@github-personal:o/r.git
  git -C "$repo" remote add web https://github.com/o/r.git
  for remote in origin personal web; do
    equals "$(fetch_url "$remote")" https://github.com/o/r.git
    equals "$(push_url "$remote")" https://github.com/o/r.git
  done
}

# A link an older install left behind must not be pulled back in.
@test "a leftover ssh-push file is no longer included" {
  printf '[url "git@github.com:"]\n\tpushInsteadOf = https://github.com/\n' > "$HOME/.gitconfig.ssh-push"
  git -C "$repo" remote add origin https://github.com/o/r.git
  equals "$(push_url)" https://github.com/o/r.git
}

@test "github https credentials come only from the gh shim" {
  helpers="$(git config --get-all credential.https://github.com.helper)"
  equals "$(printf '%s\n' "$helpers" | head -1)" ""
  contains "$(printf '%s\n' "$helpers" | tail -1)" '.local/bin/gh" auth git-credential'
}

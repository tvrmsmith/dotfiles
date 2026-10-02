load helpers/assert

# Reads dot-gitconfig directly, so the test covers the repo copy whether or not
# it is stowed, and no system config can mask a rule.
setup() {
  export GIT_CONFIG_GLOBAL="${BATS_TEST_DIRNAME}/../dot-gitconfig"
  export GIT_CONFIG_NOSYSTEM=1
  repo="$(mktemp -d)"
  git init -q "$repo"
}

teardown() { rm -rf "$repo"; }

fetch_url() { git -C "$repo" remote get-url origin; }
push_url() { git -C "$repo" remote get-url --push origin; }

@test "a work ssh remote fetches over https and pushes over ssh" {
  git -C "$repo" remote add origin git@github.com:o/r.git
  equals "$(fetch_url)" https://github.com/o/r.git
  equals "$(push_url)" git@github.com:o/r.git
}

@test "a github-personal remote fetches over https and keeps its ssh alias for push" {
  git -C "$repo" remote add origin git@github-personal:o/r.git
  equals "$(fetch_url)" https://github.com/o/r.git
  equals "$(push_url)" git@github-personal:o/r.git
}

# Without the rewrite these would push with the read-only token and get a 403.
@test "an https remote pushes over ssh" {
  git -C "$repo" remote add origin https://github.com/o/r.git
  equals "$(fetch_url)" https://github.com/o/r.git
  equals "$(push_url)" git@github.com:o/r.git
}

@test "github https credentials come only from the gh shim" {
  helpers="$(git config --get-all credential.https://github.com.helper)"
  equals "$(printf '%s\n' "$helpers" | head -1)" ""
  contains "$(printf '%s\n' "$helpers" | tail -1)" '.local/bin/gh" auth git-credential'
}

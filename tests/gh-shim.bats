load helpers/assert

# The shim decides read vs write from argv alone, so GH_SHIM_EXPLAIN covers the
# whole decision without a network call, a keychain read, or a 1Password prompt.
SHIM="${BATS_TEST_DIRNAME}/../dot-local/bin/gh"

routes() { GH_SHIM_EXPLAIN=1 bash "$SHIM" "$@"; }

# A shim only shims if it wins the PATH race. dot-zshenv prepends ~/.local/bin,
# then brew, gcloud and mise each prepend over it in dot-zprofile, which once
# left the real gh first and handed agents gh's own write-scoped token.
@test "the shim directory outranks homebrew in a login shell" {
  command -v zsh >/dev/null || skip "no zsh"
  p="$(zsh -lc 'printf %s "$PATH"' 2>/dev/null)"
  shim="$(printf '%s' "$p" | tr ':' '\n' | grep -nxF "$HOME/.local/bin" | head -1 | cut -d: -f1)"
  brew_bin="$(printf '%s' "$p" | tr ':' '\n' | grep -nxF "$(dirname "$(command -v brew 2>/dev/null || echo /nope/x)")" | head -1 | cut -d: -f1)"
  [ -n "$brew_bin" ] || skip "homebrew not on PATH here"
  if [ -z "$shim" ] || [ "$shim" -gt "$brew_bin" ]; then
    printf '~/.local/bin at position %s, homebrew at %s\n' "${shim:-absent}" "$brew_bin" >&2
    exit 1
  fi
}

# op plugin init writes `alias gh="op plugin run -- gh"`, and an alias beats
# PATH. The file still gets sourced so other plugins keep working; only gh is
# unaliased.
@test "a login shell resolves gh to the shim, with op plugins still loaded" {
  command -v zsh >/dev/null || skip "no zsh"
  [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/op/plugins.sh" ] || skip "no op plugins file"
  out="$(zsh -lic 'type gh; print "plugins=${OP_PLUGIN_ALIASES_SOURCED:-no}"' 2>/dev/null | tail -2)"
  contains "$out" "$HOME/.local/bin/gh"
  contains "$out" "plugins=1"
}

@test "read verbs stay on the silent path" {
  for args in "pr list" "pr view 12" "pr diff 12" "pr checks 12" \
              "issue list" "issue view 3" "repo view" "repo clone o/r" \
              "run view 1" "run list" "release list" "workflow list" \
              "auth status" "search prs --author @me" "--version"; do
    # shellcheck disable=SC2086
    contains "$(routes $args)" read
  done
}

@test "mutating verbs escalate" {
  for args in "pr merge 12" "pr create --fill" "pr close 12" "pr comment 12 -b x" \
              "issue create -t x" "issue comment 3 -b x" "repo delete o/r" \
              "run rerun 1" "run cancel 1" "release create v1" "secret set K" \
              "workflow run deploy" "ssh-key add k.pub" "auth login"; do
    # shellcheck disable=SC2086
    equals "$(routes $args)" write
  done
}

@test "an unknown subcommand escalates rather than passing as a read" {
  equals "$(routes gibberish thing)" write
  equals "$(routes pr somethingnew 12)" write
}

@test "gh api routes on its method, not its name" {
  contains "$(routes api user)" read
  contains "$(routes api --method GET /user)" read
  contains "$(routes api -XGET /user)" read
  equals "$(routes api -X POST /repos/o/r/issues)" write
  equals "$(routes api --method DELETE /repos/o/r)" write
}

@test "a body on gh api makes it a write even with no explicit method" {
  equals "$(routes api /repos/o/r/issues -f title=x)" write
  equals "$(routes api /repos/o/r/issues -F body=@f)" write
  equals "$(routes api /repos/o/r --input payload.json)" write
}

@test "the owner comes from the repo remote, in every URL spelling" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q .

  git remote add origin git@github.com:some-org/Thing.git
  equals "$(routes pr list)" "read some-org"

  git remote set-url origin git@github-personal:tvrmsmith/dotfiles.git
  equals "$(routes pr list)" "read tvrmsmith"

  git remote set-url origin https://github.com/octo-user/thing.git
  equals "$(routes pr list)" "read octo-user"

  rm -rf "$TMP"
}

@test "an explicit -R beats the repo the command runs in" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q .
  git remote add origin git@github.com:some-org/Thing.git

  equals "$(routes pr list -R other-org/x)" "read other-org"
  equals "$(routes pr list --repo other-org/x)" "read other-org"
  equals "$(routes pr list --repo=other-org/x)" "read other-org"
  equals "$(routes pr list -Rother-org/x)" "read other-org"
  equals "$(routes pr list -R github.com/other-org/x)" "read other-org"

  rm -rf "$TMP"
}

@test "a positional owner/repo counts, since gh rejects -R on repo commands" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q .
  git remote add origin git@github.com:some-org/Thing.git

  equals "$(routes repo view other-org/x)" "read other-org"
  equals "$(routes repo clone other-org/x)" "read other-org"
  equals "$(routes repo clone https://github.com/other-org/x)" "read other-org"
  equals "$(routes repo list other-org)" "read other-org"
  # No positional: the remote still decides.
  equals "$(routes repo view)" "read some-org"
  equals "$(routes repo list --limit 5)" "read some-org"

  rm -rf "$TMP"
}

@test "gh api takes the owner from the endpoint path" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q .
  git remote add origin git@github.com:some-org/Thing.git

  equals "$(routes api /repos/other-org/x/pulls)" "read other-org"
  equals "$(routes api repos/other-org/x)" "read other-org"
  equals "$(routes api /orgs/other-org/members)" "read other-org"
  equals "$(routes api /users/octo-user)" "read octo-user"
  # gh fills {owner} from the current repo, so it names nobody itself.
  equals "$(routes api /repos/{owner}/{repo}/pulls)" "read some-org"
  equals "$(routes api /user)" "read some-org"

  rm -rf "$TMP"
}

@test "a worktree resolves its main checkout's owner, wherever it sits" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q main
  cd main
  git remote add origin git@github.com:some-org/Thing.git
  git commit -q --allow-empty --no-gpg-sign -m init
  git worktree add -q --detach "$TMP/far-away" HEAD

  cd "$TMP/far-away"
  equals "$(routes pr list)" "read some-org"

  cd "$TMP"
  rm -rf "$TMP"
}

@test "a filesystem remote is skipped for one that names GitHub" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q .

  # A gate-repo clone: origin is a path on disk, which must not parse as an owner.
  git remote add origin /Users/someone/.no-mistakes/repos/abc123.git
  equals "$(routes pr list)" "read TrevorSmith-Wellsky"

  git remote add upstream git@github-personal:tvrmsmith/thing.git
  equals "$(routes pr list)" "read tvrmsmith"

  rm -rf "$TMP"
}

@test "outside a repo the owner falls back on the directory rule" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  equals "$(routes pr list)" "read TrevorSmith-Wellsky"

  mkdir -p "$HOME/dev/personal/gh-shim-test" && cd "$HOME/dev/personal/gh-shim-test"
  equals "$(routes pr list)" "read tvrmsmith"

  rmdir "$HOME/dev/personal/gh-shim-test"
  rm -rf "$TMP"
}

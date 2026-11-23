load helpers/assert

# GH_SHIM_EXPLAIN prints the owner the shim resolved and which keyring entry, if
# any, it would use, and runs nothing. Owner tests read the second field.
SHIM="${BATS_TEST_DIRNAME}/../dot-local/bin/gh"

routes() { GH_SHIM_EXPLAIN=1 bash "$SHIM" "$@"; }
owner() { routes "$@" | awk '{print $2}'; }

# The token tests stub `security`, so pin gh-keyring to the macOS backend
# whatever this suite runs on. The Linux backend has its own test below and in
# tests/gh-keyring.bats.
export GH_KEYRING_BACKEND=security

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
# The test above runs `zsh -lc`, which never reads .zshrc, so it passed while
# `mise activate` and the bun block were burying ~/.local/bin to fourth in every
# shell Trevor actually types in. It survived only because neither mise nor bun
# ships a `gh`. Hence this one: the hoist has to run after .zshrc too.
@test "the shim directory outranks every activation prepend interactively" {
  command -v zsh >/dev/null || skip "no zsh"
  p="$(zsh -lic 'printf %s "$PATH"' 2>/dev/null)"
  at() { printf '%s' "$p" | tr ':' '\n' | grep -nxF "$1" | head -1 | cut -d: -f1; }
  shim="$(at "$HOME/.local/bin")"
  [ -n "$shim" ] || { echo "~/.local/bin is not on the interactive PATH" >&2; exit 1; }
  for later in "$HOME/.bun/bin" "$HOME/.local/share/mise/shims" /opt/homebrew/bin; do
    pos="$(at "$later")"
    [ -n "$pos" ] || continue
    if [ "$shim" -gt "$pos" ]; then
      printf '~/.local/bin at %s, %s at %s\n' "$shim" "$later" "$pos" >&2
      exit 1
    fi
  done
}

@test "a login shell resolves gh to the shim, with op plugins still loaded" {
  command -v zsh >/dev/null || skip "no zsh"
  [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/op/plugins.sh" ] || skip "no op plugins file"
  out="$(zsh -lic 'type gh; print "plugins=${OP_PLUGIN_ALIASES_SOURCED:-no}"' 2>/dev/null | tail -2)"
  contains "$out" "$HOME/.local/bin/gh"
  contains "$out" "plugins=1"
}

# The two tests above defend a race the shim should not be in at all. install.sh
# runs `brew unlink gh`, so the shim is the only `gh` any PATH can reach and
# order stops mattering. `brew upgrade gh` relinks, which is what this catches.
@test "no second gh competes with the shim on PATH" {
  command -v zsh >/dev/null || skip "no zsh"
  command -v brew >/dev/null 2>&1 || skip "no homebrew"
  found="$(zsh -lic 'whence -ap gh' 2>/dev/null)"
  [ -n "$found" ] || { echo "no gh on the interactive PATH at all" >&2; exit 1; }
  others="$(printf '%s\n' "$found" | grep -vxF "$HOME/.local/bin/gh" || true)"
  if [ -n "$others" ]; then
    printf 'gh also resolves at:\n%s\nrun ./install.sh to unlink it\n' "$others" >&2
    exit 1
  fi
}

# With brew's gh unlinked there is nothing named gh on PATH, so the shim has to
# reach the keg through Homebrew's opt link or every command exits 127.
@test "the shim finds the real binary with no gh on PATH" {
  command -v brew >/dev/null 2>&1 || skip "no homebrew"
  brew list --formula gh >/dev/null 2>&1 || skip "gh not installed with brew"
  [ -x "$(brew --prefix)/opt/gh/bin/gh" ] || { echo "brew's gh keg has no opt link" >&2; exit 1; }
  equals "$(PATH=/usr/bin:/bin GH_SHIM_EXPLAIN=1 bash "$SHIM" pr list 2>&1 | awk '{print $1}')" "owner"
}

@test "the owner comes from the repo remote, in every URL spelling" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q .

  git remote add origin git@github.com:some-org/Thing.git
  equals "$(owner pr list)" "some-org"

  git remote set-url origin git@github-personal:tvrmsmith/dotfiles.git
  equals "$(owner pr list)" "tvrmsmith"

  git remote set-url origin https://github.com/octo-user/thing.git
  equals "$(owner pr list)" "octo-user"

  rm -rf "$TMP"
}

@test "an explicit -R beats the repo the command runs in" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q .
  git remote add origin git@github.com:some-org/Thing.git

  equals "$(owner pr list -R other-org/x)" "other-org"
  equals "$(owner pr list --repo other-org/x)" "other-org"
  equals "$(owner pr list --repo=other-org/x)" "other-org"
  equals "$(owner pr list -Rother-org/x)" "other-org"
  equals "$(owner pr list -R github.com/other-org/x)" "other-org"

  rm -rf "$TMP"
}

@test "a positional owner/repo counts, since gh rejects -R on repo commands" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q .
  git remote add origin git@github.com:some-org/Thing.git

  equals "$(owner repo view other-org/x)" "other-org"
  equals "$(owner repo clone other-org/x)" "other-org"
  equals "$(owner repo clone https://github.com/other-org/x)" "other-org"
  equals "$(owner repo list other-org)" "other-org"
  # No positional: the remote still decides.
  equals "$(owner repo view)" "some-org"
  equals "$(owner repo list --limit 5)" "some-org"

  rm -rf "$TMP"
}

@test "gh api takes the owner from the endpoint path" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q .
  git remote add origin git@github.com:some-org/Thing.git

  equals "$(owner api /repos/other-org/x/pulls)" "other-org"
  equals "$(owner api repos/other-org/x)" "other-org"
  equals "$(owner api /orgs/other-org/members)" "other-org"
  equals "$(owner api /users/octo-user)" "octo-user"
  # gh fills {owner} from the current repo, so it names nobody itself.
  equals "$(owner api /repos/{owner}/{repo}/pulls)" "some-org"
  equals "$(owner api /user)" "some-org"

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
  equals "$(owner pr list)" "some-org"

  cd "$TMP"
  rm -rf "$TMP"
}

@test "a filesystem remote is skipped for one that names GitHub" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q .

  # A gate-repo clone: origin is a path on disk, which must not parse as an owner.
  git remote add origin /Users/someone/.no-mistakes/repos/abc123.git
  equals "$(owner pr list)" "TrevorSmith-Wellsky"

  git remote add upstream git@github-personal:tvrmsmith/thing.git
  equals "$(owner pr list)" "tvrmsmith"

  rm -rf "$TMP"
}

# The owner loop returns on its first match. While it streamed remote URLs from
# a pipe, the writer was still feeding the closed pipe, and under a parent that
# ignores SIGPIPE (common for agent launchers) GNU cut printed "write error:
# Broken pipe" on every Linux gh call. Enough remotes to overflow a pipe buffer
# make the race certain rather than lucky.
@test "resolving the owner from a non-origin remote writes nothing to stderr" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q .
  git remote add origin /srv/gate.git
  for i in $(seq 1 3000); do printf '[remote "r%s"]\n\turl = git@github.com:o%s/x.git\n' "$i" "$i"; done >> .git/config

  err="$( (trap '' PIPE; GH_SHIM_EXPLAIN=1 bash "$SHIM" pr list) 2>&1 >/dev/null )"
  is_empty "$err"
  equals "$(owner pr list)" "o1"

  rm -rf "$TMP"
}

@test "outside a repo the owner falls back on the directory rule" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  equals "$(owner pr list)" "TrevorSmith-Wellsky"

  # A scratch HOME: the directory rule reads $HOME, and a repo left under the
  # real ~/dev/personal by a failed run broke every run after it.
  export HOME="$TMP/home"
  mkdir -p "$HOME/dev/personal/gh-shim-test" && cd "$HOME/dev/personal/gh-shim-test"
  equals "$(owner pr list)" "tvrmsmith"

  rm -rf "$TMP"
}


# GH_SHIM_EXPLAIN stops before running gh, so the token choice needs the real
# path: a stub `security` holding tokens, a stub `gh` that reports whichever
# token it was handed, and a stub `op` that would show any 1Password call.
stub_bin() {
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  printf '#!/bin/bash\necho "token=$GH_TOKEN"\n' > "$BIN/gh"
  printf '#!/bin/bash\necho "OP CALLED $*"\n' > "$BIN/op"
  chmod +x "$BIN"/gh "$BIN"/op
}

# security(1) stub: answers the gh-token service for the owners given as
# owner=token pairs, and nothing else.
stub_security() {
  {
    echo '#!/bin/bash'
    echo 'svc=""; acct=""'
    echo 'while [ $# -gt 0 ]; do case "$1" in -s) svc="$2"; shift 2 ;; -a) acct="$2"; shift 2 ;; *) shift ;; esac; done'
    echo '[ "$svc" = gh-token ] || exit 1'
    echo 'case "$acct" in'
    for pair in "$@"; do echo "  ${pair%%=*}) echo ${pair#*=}; exit 0 ;;"; done
    echo 'esac'
    echo 'exit 1'
  } > "$BIN/security"
  chmod +x "$BIN/security"
}

@test "the repo owner's token is handed to gh, for writes and reads alike" {
  TMP="$(mktemp -d)"; stub_bin; stub_security some-org=org-token tvrmsmith=personal-token
  cd "$TMP"
  git init -q .
  git remote add origin git@github.com:some-org/Thing.git

  for args in "pr list" "pr create --fill" "pr merge 12 --squash" "api -X PUT /repos/some-org/Thing/pulls/1/merge" "auth git-credential get"; do
    # shellcheck disable=SC2086
    equals "$(PATH="$BIN:$PATH" bash "$SHIM" $args 2>&1)" "token=org-token"
  done

  rm -rf "$TMP"
}

@test "nothing ever asks 1Password" {
  TMP="$(mktemp -d)"; stub_bin; stub_security
  cd "$TMP"
  git init -q .
  git remote add origin git@github.com:nobody-here/thing.git

  out="$(PATH="$BIN:$PATH" bash "$SHIM" pr merge 12 2>&1)"
  lacks "$out" "OP CALLED"
  equals "$out" "token="

  rm -rf "$TMP"
}

@test "an explicit GH_TOKEN wins over the keyring" {
  TMP="$(mktemp -d)"; stub_bin; stub_security some-org=org-token
  cd "$TMP"
  git init -q .
  git remote add origin git@github.com:some-org/Thing.git

  equals "$(GH_TOKEN=mine PATH="$BIN:$PATH" bash "$SHIM" pr list 2>&1)" "token=mine"

  rm -rf "$TMP"
}

@test "a third-party owner falls back on the directory's account" {
  TMP="$(mktemp -d)"; stub_bin; stub_security tvrmsmith=personal-token TrevorSmith-Wellsky=work-token
  export HOME="$TMP/home"   # scratch: the directory rule reads $HOME
  mkdir -p "$HOME/dev/personal/gh-shim-borrow" && cd "$HOME/dev/personal/gh-shim-borrow"
  git init -q .
  git remote add origin git@github.com:third-party/thing.git
  equals "$(PATH="$BIN:$PATH" bash "$SHIM" pr create --fill 2>&1)" "token=personal-token"
  equals "$(PATH="$BIN:$PATH" routes pr list)" "owner third-party token tvrmsmith"

  mkdir -p "$TMP/work" && cd "$TMP/work"
  git init -q .
  git remote add origin git@github.com:third-party/thing.git
  equals "$(PATH="$BIN:$PATH" bash "$SHIM" pr list 2>&1)" "token=work-token"

  cd "$TMP"
  rm -rf "$TMP"
}

@test "a keyring token that is only whitespace counts as no token" {
  # A lone CR in the keyring was passed to gh as the Authorization header.
  TMP="$(mktemp -d)"; stub_bin
  printf '#!/bin/bash\nprintf "\\r"; exit 0\n' > "$BIN/security"
  chmod +x "$BIN/security"
  cd "$TMP"
  git init -q .
  git remote add origin git@github.com:tvrmsmith/thing.git

  equals "$(PATH="$BIN:$PATH" bash "$SHIM" pr list 2>&1)" "token="

  rm -rf "$TMP"
}

# install.sh makes ~/.local/bin a real directory, so stow links each file in it
# separately and a newly added helper has no link there until the next install.
# The shim has to find gh-keyring beside its real file in the repo.
@test "a stowed shim finds gh-keyring in the repo when its link dir lacks one" {
  TMP="$(mktemp -d)"; stub_bin; stub_security some-org=stored-token
  LINKS="$TMP/links"
  mkdir -p "$LINKS"
  ln -s "$SHIM" "$LINKS/gh"
  cd "$TMP"
  git init -q .
  git remote add origin git@github.com:some-org/Thing.git

  equals "$(PATH="$BIN:$PATH" bash "$LINKS/gh" pr list 2>&1)" "token=stored-token"

  rm -rf "$TMP"
}

@test "on Linux the token comes from the Secret Service" {
  TMP="$(mktemp -d)"; stub_bin
  cat > "$BIN/secret-tool" <<'STUB'
#!/bin/bash
[ "$1" = lookup ] && [ "$3" = gh-token ] && [ "$5" = some-org ] || exit 1
printf linux-token
STUB
  chmod +x "$BIN/secret-tool"
  cd "$TMP"
  git init -q .
  git remote add origin git@github.com:some-org/Thing.git

  equals "$(GH_KEYRING_BACKEND=secret-tool PATH="$BIN:$PATH" bash "$SHIM" pr list 2>&1)" "token=linux-token"

  rm -rf "$TMP"
}

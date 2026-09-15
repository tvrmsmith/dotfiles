load helpers/assert

# The shim decides read vs write from argv alone, so GH_SHIM_EXPLAIN covers the
# whole decision without a network call, a keychain read, or a 1Password prompt.
SHIM="${BATS_TEST_DIRNAME}/../dot-local/bin/gh"

routes() { GH_SHIM_EXPLAIN=1 bash "$SHIM" "$@"; }

# Every tier now reports the owner it resolved, so a test that only cares which
# tier was chosen takes the first field rather than pinning the owner too.
tier() { routes "$@" | awk '{print $1}'; }

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

# The PR lifecycle verbs used to sit here. They moved to the pr-write tier and
# have their own test; everything below stays on the approval path.
@test "mutating verbs escalate" {
  for args in "pr merge 12" \
              "issue create -t x" "issue comment 3 -b x" "repo delete o/r" \
              "run rerun 1" "run cancel 1" "release create v1" "secret set K" \
              "workflow run deploy" "ssh-key add k.pub" "auth login"; do
    # shellcheck disable=SC2086
    equals "$(tier $args)" write
  done
}

# Opening a PR is the write agents do constantly. GitHub gates it on
# `Pull requests: write` while merging needs `Contents: write`, so a token with
# the first and not the second opens PRs and cannot merge by any route.
@test "the PR lifecycle routes to the pr-write token" {
  for args in "pr create --fill" "pr comment 12 -b x" "pr edit 12 --title t" \
              "pr ready 12" "pr draft 12" "pr close 12" "pr reopen 12"; do
    # shellcheck disable=SC2086
    contains "$(routes $args)" pr-write
  done
}

@test "merging is never a pr-write, in any spelling" {
  for args in "pr merge 12" "pr merge 12 --auto" "pr merge 12 --squash" \
              "api -X PUT /repos/o/r/pulls/12/merge" \
              "api -X POST /repos/o/r/pulls/12/merge-async" \
              "api -X PUT /repos/o/r/pulls/12/update-branch"; do
    # shellcheck disable=SC2086
    equals "$(tier $args)" write
  done
}

# Approving cannot merge either, but it is how a required-approval rule gets
# satisfied, and an agent should not clear that bar for its own PR.
@test "submitting a review still needs an approval" {
  equals "$(tier pr review 12 --approve)" write
  equals "$(tier api -X POST /repos/o/r/pulls/12/reviews -f event=APPROVE)" write
  equals "$(tier api -X POST /repos/o/r/pulls/12/requested_reviewers -f reviewers[]=x)" write
}

@test "the REST spellings of the PR lifecycle route to pr-write too" {
  contains "$(routes api -X POST /repos/o/r/pulls -f title=x)" pr-write
  # gh infers POST from a body, so the method is usually left off.
  contains "$(routes api /repos/o/r/pulls -f title=x -f head=b -f base=main)" pr-write
  contains "$(routes api -X PATCH /repos/o/r/pulls/12 -f state=closed)" pr-write
  contains "$(routes api -X POST /repos/o/r/issues/12/comments -f body=x)" pr-write

  # A different verb on the same path is not covered.
  equals "$(tier api -X DELETE /repos/o/r/pulls/12)" write
  # Neither is a different resource.
  equals "$(tier api -X POST /repos/o/r/releases -f tag_name=v1)" write
  equals "$(tier api -X POST /repos/o/r/git/blobs -f content=x)" write
}

@test "a pr-write resolves an owner, so it can pick that owner's token" {
  TMP="$(mktemp -d)"
  cd "$TMP"
  git init -q .
  git remote add origin git@github.com:some-org/Thing.git

  equals "$(routes pr create --fill)" "pr-write some-org"
  equals "$(routes pr create -R other-org/x --fill)" "pr-write other-org"
  equals "$(routes api -X POST /repos/other-org/x/pulls -f title=t)" "pr-write other-org"

  rm -rf "$TMP"
}

@test "an unknown subcommand escalates rather than passing as a read" {
  equals "$(tier gibberish thing)" write
  equals "$(tier pr somethingnew 12)" write
}

@test "gh api routes on its method, not its name" {
  contains "$(routes api user)" read
  contains "$(routes api --method GET /user)" read
  contains "$(routes api -XGET /user)" read
  equals "$(tier api -X POST /repos/o/r/issues)" write
  equals "$(tier api --method DELETE /repos/o/r)" write
}

@test "a body on gh api makes it a write even with no explicit method" {
  equals "$(tier api /repos/o/r/issues -f title=x)" write
  equals "$(tier api /repos/o/r/issues -F body=@f)" write
  equals "$(tier api /repos/o/r --input payload.json)" write
}

# Every GraphQL call POSTs a `-f query=` body, so the body rule alone made all of
# them writes. The daemon polling branch protection over GraphQL then spent an
# approval per poll.
@test "a graphql query is a read, a graphql mutation is not" {
  contains "$(routes api graphql -f query='query { viewer { login } }')" read
  contains "$(routes api --hostname github.com graphql -f query='query($o: String!) { repository(owner: $o) { id } }' -f o=x)" read
  # A leading newline is how a multi-line query usually arrives.
  contains "$(routes api graphql -f query='
    query { viewer { login } }')" read
  contains "$(routes api graphql -f query='{ viewer { login } }')" read

  equals "$(tier api graphql -f query='mutation { addStar(input: {}) { clientMutationId } }')" write
  # Not inspectable, so it keeps the prompting path.
  equals "$(tier api graphql -f query=@op.graphql)" write
  equals "$(tier api graphql --input q.json)" write
  # No body at all: nothing to mutate with, so the generic api rule's read is right.
  contains "$(routes api graphql)" read
  # The exemption is for graphql alone; a REST body is still a write.
  equals "$(tier api /repos/o/r/issues -f query=query)" write
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

# GH_SHIM_EXPLAIN stops before the keychain, so the token choice needs the real
# path: a stub `security` holding one owner's token, and a stub `gh` that
# reports whichever token it was handed.
@test "a read for an owner with no token borrows one instead of prompting" {
  # The no-mistakes daemon polls an upstream repo owned by nobody we hold a
  # token for. Escalating that read fired a 1Password approval every few
  # seconds, and no approval protects a public read.
  TMP="$(mktemp -d)"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  cat > "$BIN/security" <<'STUB'
#!/bin/bash
case " $* " in *" -a tvrmsmith "*) echo personal-token; exit 0 ;; esac
exit 1
STUB
  printf '#!/bin/bash\necho "token=$GH_TOKEN"\n' > "$BIN/gh"
  printf '#!/bin/bash\nexit 0\n' > "$BIN/op"
  chmod +x "$BIN"/*

  mkdir -p "$HOME/dev/personal/gh-shim-borrow" && cd "$HOME/dev/personal/gh-shim-borrow"
  git init -q .
  git remote add origin git@github.com:third-party/thing.git

  out="$(PATH="$BIN:$PATH" bash "$SHIM" pr list 2>&1)"
  equals "$out" "token=personal-token"

  cd "$TMP"
  rm -rf "$HOME/dev/personal/gh-shim-borrow" "$TMP"
}

@test "a pr-write uses the owner's gh-prwrite entry, not the read-only one" {
  TMP="$(mktemp -d)"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  cat > "$BIN/security" <<'STUB'
#!/bin/bash
svc=""; acct=""
while [ $# -gt 0 ]; do
  case "$1" in -s) svc="$2"; shift 2 ;; -a) acct="$2"; shift 2 ;; *) shift ;; esac
done
[ "$svc" = gh-prwrite ] && [ "$acct" = some-org ] && { echo pr-token; exit 0; }
[ "$svc" = gh-readonly ] && [ "$acct" = some-org ] && { echo read-token; exit 0; }
exit 1
STUB
  printf '#!/bin/bash\necho "token=$GH_TOKEN"\n' > "$BIN/gh"
  printf '#!/bin/bash\necho "op $*"\n' > "$BIN/op"
  chmod +x "$BIN"/*

  cd "$TMP"
  git init -q .
  git remote add origin git@github.com:some-org/Thing.git

  equals "$(PATH="$BIN:$PATH" bash "$SHIM" pr create --fill 2>&1)" "token=pr-token"
  # The read tier still picks the read-only entry.
  equals "$(PATH="$BIN:$PATH" bash "$SHIM" pr list 2>&1)" "token=read-token"

  rm -rf "$TMP"
}

# The borrow loop exists so a public read finds any valid token. That reasoning
# does not carry to a credential that can write, so a PR against an owner we hold
# no PR token for prompts instead of reaching for someone else's.
@test "a pr-write never borrows another owner's token" {
  TMP="$(mktemp -d)"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  cat > "$BIN/security" <<'STUB'
#!/bin/bash
case " $* " in *" -a tvrmsmith "*) echo personal-token; exit 0 ;; esac
exit 1
STUB
  printf '#!/bin/bash\necho "REAL GH RAN token=$GH_TOKEN"\n' > "$BIN/gh"
  printf '#!/bin/bash\necho "op $*"\n' > "$BIN/op"
  chmod +x "$BIN"/*

  mkdir -p "$HOME/dev/personal/gh-shim-prborrow" && cd "$HOME/dev/personal/gh-shim-prborrow"
  git init -q .
  git remote add origin git@github.com:third-party/thing.git

  out="$(XDG_STATE_HOME="$TMP/state" XDG_CONFIG_HOME="$TMP/config" \
    PATH="$BIN:$PATH" bash "$SHIM" pr create --fill 2>&1)"
  contains "$out" "op plugin run -- gh pr create --fill"
  lacks "$out" "personal-token"

  cd "$TMP"
  rm -rf "$HOME/dev/personal/gh-shim-prborrow" "$TMP"
}

@test "a write is never satisfied by a borrowed token" {
  TMP="$(mktemp -d)"
  BIN="$TMP/bin"
  mkdir -p "$BIN"
  printf '#!/bin/bash\necho personal-token\n' > "$BIN/security"
  printf '#!/bin/bash\necho "REAL GH RAN"\n' > "$BIN/gh"
  printf '#!/bin/bash\necho "op $*"\n' > "$BIN/op"
  chmod +x "$BIN"/*

  cd "$TMP"
  # Own state and config dirs: the escalation the shim logs here is a test, not
  # a real one, and the write map must be this test's, not the machine's.
  out="$(XDG_STATE_HOME="$TMP/state" XDG_CONFIG_HOME="$TMP/config" \
    PATH="$BIN:$PATH" bash "$SHIM" pr merge 12 2>&1)"
  contains "$out" "op plugin run -- gh pr merge 12"
  lacks "$out" "token="
  contains "$(cat "$TMP/state/gh-shim.log")" "gh pr merge 12"

  rm -rf "$TMP"
}

# The write tier used to hand credential selection to `op plugin run`, which
# pins one account in its own config and then lets a per-terminal selection
# override it. Merging a personal PR authenticated as the work user and 403'd.
# See dotfiles-4ul.
@test "a write resolves its 1Password account from the repo owner" {
  TMP="$(mktemp -d)"
  BIN="$TMP/bin"
  mkdir -p "$BIN" "$TMP/config/gh-shim"
  printf '#!/bin/bash\nexit 1\n' > "$BIN/security"
  printf '#!/bin/bash\necho "GH RAN token=$GH_TOKEN"\n' > "$BIN/gh"
  # Echoes what it was asked for, and answers with a token naming the account,
  # so one run shows both which reference was read and what reached gh.
  printf '#!/bin/bash\necho "op $*" >&2\n[ "$1" = read ] && echo "tok-$3"\n' > "$BIN/op"
  chmod +x "$BIN"/*
  cat > "$TMP/config/gh-shim/write-tokens" <<'MAP'
# comment lines and blanks are skipped

mine   my.example.com    op://vault-a/item-a/token
theirs work.example.com  op://vault-b/item-b/token
MAP

  cd "$TMP"
  run_write() {
    XDG_STATE_HOME="$TMP/state" XDG_CONFIG_HOME="$TMP/config" \
      PATH="$BIN:$PATH" bash "$SHIM" "$@" 2>&1
  }

  out="$(run_write pr merge 12 -R mine/repo)"
  contains "$out" "op read --account my.example.com --no-newline op://vault-a/item-a/token"
  contains "$out" "GH RAN token=tok-my.example.com"

  out="$(run_write pr merge 12 -R theirs/repo)"
  contains "$out" "op read --account work.example.com --no-newline op://vault-b/item-b/token"
  contains "$out" "GH RAN token=tok-work.example.com"

  # An owner the map does not name keeps the old path rather than failing.
  contains "$(run_write pr merge 12 -R nobody/repo)" "op plugin run -- gh"

  rm -rf "$TMP"
}

# The reason the write tier reads one reference rather than running `op run`:
# op run resolves every op:// reference in the inherited environment, so a shell
# exporting a work-vault reference broke each personal-account write and, on a
# work write, fetched unrelated secrets into gh's environment.
@test "a write reads one reference and ignores op:// vars in the environment" {
  TMP="$(mktemp -d)"
  BIN="$TMP/bin"
  mkdir -p "$BIN" "$TMP/config/gh-shim"
  printf '#!/bin/bash\nexit 1\n' > "$BIN/security"
  printf '#!/bin/bash\necho "GH RAN stray=${STRAY_REF:-unset}"\n' > "$BIN/gh"
  printf '#!/bin/bash\necho "op $*" >&2\n[ "$1" = read ] && echo tok\n' > "$BIN/op"
  chmod +x "$BIN"/*
  printf 'mine my.example.com op://vault-a/item-a/token\n' \
    > "$TMP/config/gh-shim/write-tokens"

  cd "$TMP"
  out="$(STRAY_REF='op://Employee/Some Token/credential' \
    XDG_STATE_HOME="$TMP/state" XDG_CONFIG_HOME="$TMP/config" \
    PATH="$BIN:$PATH" bash "$SHIM" pr merge 12 -R mine/repo 2>&1)"

  # One op call, for our reference only. The stray variable never reaches op.
  op_calls="$(printf '%s\n' "$out" | grep '^op ')"
  equals "$(printf '%s\n' "$op_calls" | wc -l | tr -d ' ')" 1
  lacks "$op_calls" "Employee"
  lacks "$op_calls" "op run"
  lacks "$op_calls" "env-file"
  # The stray variable is passed through untouched rather than resolved.
  contains "$out" "GH RAN stray=op://Employee/Some Token/credential"

  rm -rf "$TMP"
}

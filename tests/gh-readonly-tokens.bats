load helpers/assert

# The wizard's only durable output is a set of `security add-generic-password`
# calls, so a stub `security` on PATH turns the whole thing into a testable
# function of the keystrokes. A stub browser keeps the run headless.
WIZARD="${BATS_TEST_DIRNAME}/../extras/gh-readonly-tokens.sh"

setup() {
  BIN="$(mktemp -d)"
  export LOG="$BIN/calls.log"
  # PRESENT and PRESENT_PR list the owners the fake keychain already holds, per
  # service, so a test can replay a re-run rather than only a first run. Keeping
  # them separate matters: an owner can hold a read token and no PR token, which
  # is every owner's state on the first run after the PR tier landed.
  cat > "$BIN/security" <<'EOF'
#!/bin/bash
echo "security $*" >> "$LOG"
if [ "$1" = find-generic-password ]; then
  svc=""; acct=""
  while [ $# -gt 0 ]; do
    case "$1" in -s) svc="$2"; shift 2 ;; -a) acct="$2"; shift 2 ;; *) shift ;; esac
  done
  case "$svc" in
    gh-prwrite) held="$PRESENT_PR" ;;
    *)          held="$PRESENT" ;;
  esac
  for owner in $held; do [ "$owner" = "$acct" ] && exit 0; done
  exit 1
fi
exit 0
EOF
  for c in open xdg-open wslview explorer.exe; do
    printf '#!/bin/bash\necho "BROWSER" >> "$LOG"\n' > "$BIN/$c"
  done
  printf '#!/bin/bash\nexit 0\n' > "$BIN/gh"
  chmod +x "$BIN"/*
  export PATH="$BIN:$PATH" ENV_FILE="$BIN/.env" PRESENT="" PRESENT_PR=""
}

teardown() { rm -rf "$BIN"; }

# Keystrokes in, "owner <- token" lines out, one per token actually stored.
run_wizard() { printf '%b' "$1" | bash "$WIZARD" >/dev/null 2>&1 || true
  grep add-generic-password "$LOG" | sed -E 's/.*-a ([^ ]+) -w ([^ ]+).*/\1 <- \2/'
}

# Same, but naming the keychain service, which is what separates a read-only
# token from a PR-write one.
run_wizard_svc() { printf '%b' "$1" | bash "$WIZARD" >/dev/null 2>&1 || true
  grep add-generic-password "$LOG" | sed -E 's/.*-s ([^ ]+) -a ([^ ]+) -w ([^ ]+).*/\1 \2 <- \3/'
}

@test "a clean run stores one token per owner" {
  out="$(run_wizard '\n\np-tok\n\nw-tok\nsome-org\norg-tok\ndone\n\n')"
  equals "$out" "tvrmsmith <- p-tok
TrevorSmith-Wellsky <- w-tok
some-org <- org-tok"
}

@test "naming your own login as the org refuses rather than clobbering" {
  # The slip that cost a work-user token: `security -U` overwrites in silence,
  # so the org token landed on the work-user key and the work-user token went.
  out="$(run_wizard '\n\np-tok\n\nw-tok\nTrevorSmith-Wellsky\norg-tok\n\ndone\n\n')"
  equals "$out" "tvrmsmith <- p-tok
TrevorSmith-Wellsky <- w-tok"
}

@test "an owner that already has a token is left alone, and opens no browser" {
  PRESENT="tvrmsmith mediwareinc"
  out="$(run_wizard '\n\nn\n\nnew-tok\ndone\n\n')"
  equals "$out" "TrevorSmith-Wellsky <- new-tok"
  equals "$(grep -c BROWSER "$LOG")" 1
}

@test "answering yes replaces the token an owner already has" {
  PRESENT="tvrmsmith"
  out="$(run_wizard '\n\ny\nreplaced\n\nw-tok\ndone\n\n')"
  equals "$out" "tvrmsmith <- replaced
TrevorSmith-Wellsky <- w-tok"
}

@test "the org loop ends on done, not on a bare Enter mid-run" {
  # Enter means "accept the default" at every other prompt, so it must not be
  # the only way out of the loop.
  out="$(run_wizard '\n\np-tok\n\nw-tok\nfirst-org\na\nsecond-org\nb\ndone\n\n')"
  equals "$out" "tvrmsmith <- p-tok
TrevorSmith-Wellsky <- w-tok
first-org <- a
second-org <- b"
}

# The PR stage offers each owner the earlier stages named, so an owner is typed
# once and gets both tokens. A PR token is opt-in per owner: declining leaves
# that owner prompting on `pr create`, which is the pre-existing behaviour.
@test "the PR stage stores under gh-prwrite, and only for owners you accept" {
  out="$(run_wizard_svc '\n\np-tok\n\nw-tok\ndone\ny\npr-tok\nn\n\n')"
  equals "$out" "gh-readonly tvrmsmith <- p-tok
gh-readonly TrevorSmith-Wellsky <- w-tok
gh-prwrite tvrmsmith <- pr-tok"
}

@test "declining every owner in the PR stage stores no PR token at all" {
  out="$(run_wizard_svc '\n\np-tok\n\nw-tok\ndone\nn\nn\n\n')"
  lacks "$out" "gh-prwrite"
}

# The bug this pins: OWNERS_SEEN only held owners typed this run, so a re-run
# that kept every existing token and answered "done" at the org stage never
# offered the orgs a PR token. They now come from the machine's own remotes.
@test "a re-run that keeps every token still offers orgs a PR token" {
  PRESENT="tvrmsmith TrevorSmith-Wellsky some-org"
  # A checkout whose remote names an org, which is where stage 4 finds it.
  mkdir -p "$BIN/dev/some-repo"
  git -C "$BIN/dev/some-repo" init -q .
  git -C "$BIN/dev/some-repo" remote add origin git@github.com:some-org/thing.git
  export HOME="$BIN"

  #        banner  personal  keep  work  keep  org=done  then the PR stage
  out="$(run_wizard_svc '\n\nn\n\nn\ndone\nn\nn\ny\norg-pr\ndone\n\n')"
  contains "$out" "gh-prwrite some-org <- org-pr"
}

@test "an owner with no read token is not offered a PR token" {
  PRESENT="tvrmsmith"
  mkdir -p "$BIN/dev/some-repo"
  git -C "$BIN/dev/some-repo" init -q .
  git -C "$BIN/dev/some-repo" remote add origin git@github.com:stranger-org/thing.git
  export HOME="$BIN"

  out="$(run_wizard_svc '\n\nn\n\nw-tok\ndone\nn\nn\ndone\n\n')"
  lacks "$out" "stranger-org"
}

@test "an org named in stage 3 is offered a PR token too" {
  out="$(run_wizard_svc '\n\np-tok\n\nw-tok\nsome-org\norg-tok\ndone\nn\nn\ny\norg-pr\n\n')"
  contains "$out" "gh-prwrite some-org <- org-pr"
  # The org's read token is untouched by the PR stage.
  contains "$out" "gh-readonly some-org <- org-tok"
}

@test "no token is ever written to a file" {
  run_wizard '\n\np-tok\n\nw-tok\ndone\n\n' >/dev/null
  [ -f "$ENV_FILE" ] && lacks "$(cat "$ENV_FILE")" "p-tok"
  lacks "$(cat "$LOG")" "write_env"
}

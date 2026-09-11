load helpers/assert

# The wizard's only durable output is a set of `security add-generic-password`
# calls, so a stub `security` on PATH turns the whole thing into a testable
# function of the keystrokes. A stub browser keeps the run headless.
WIZARD="${BATS_TEST_DIRNAME}/../extras/gh-readonly-tokens.sh"

setup() {
  BIN="$(mktemp -d)"
  export LOG="$BIN/calls.log"
  # PRESENT lists the owners the fake keychain already holds, so a test can
  # replay a re-run rather than only a first run.
  cat > "$BIN/security" <<'EOF'
#!/bin/bash
echo "security $*" >> "$LOG"
if [ "$1" = find-generic-password ]; then
  for owner in $PRESENT; do
    case " $* " in *" -a $owner "*) exit 0 ;; esac
  done
  exit 1
fi
exit 0
EOF
  for c in open xdg-open wslview explorer.exe; do
    printf '#!/bin/bash\necho "BROWSER" >> "$LOG"\n' > "$BIN/$c"
  done
  printf '#!/bin/bash\nexit 0\n' > "$BIN/gh"
  chmod +x "$BIN"/*
  export PATH="$BIN:$PATH" ENV_FILE="$BIN/.env" PRESENT=""
}

teardown() { rm -rf "$BIN"; }

# Keystrokes in, "owner <- token" lines out, one per token actually stored.
run_wizard() { printf '%b' "$1" | bash "$WIZARD" >/dev/null 2>&1 || true
  grep add-generic-password "$LOG" | sed -E 's/.*-a ([^ ]+) -w ([^ ]+).*/\1 <- \2/'
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

@test "no token is ever written to a file" {
  run_wizard '\n\np-tok\n\nw-tok\ndone\n\n' >/dev/null
  [ -f "$ENV_FILE" ] && lacks "$(cat "$ENV_FILE")" "p-tok"
  lacks "$(cat "$LOG")" "write_env"
}

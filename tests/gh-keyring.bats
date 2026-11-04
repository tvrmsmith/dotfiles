load helpers/assert

# gh-keyring is the only file that knows which OS keyring holds the gh tokens.
# Each backend is a stub on PATH that logs its argv, so these pin the exact
# calls without touching a real keychain or Secret Service.
KEYRING="${BATS_TEST_DIRNAME}/../dot-local/bin/gh-keyring"

setup() {
  BIN="$(mktemp -d)"
  export LOG="$BIN/calls.log"
  for tool in security secret-tool; do
    cat > "$BIN/$tool" <<'EOF'
#!/bin/bash
stdin=""
[ -t 0 ] || stdin="$(cat)"
echo "$(basename "$0") $* ${stdin:+<stdin:$stdin>}" >> "$LOG"
case "$1" in find-generic-password | lookup) printf stored-token ;; esac
EOF
  done
  chmod +x "$BIN"/*
}
teardown() { rm -rf "$BIN"; }

keyring() { PATH="$BIN:$PATH" bash "$KEYRING" "$@"; }

@test "macOS get reads the keychain by service and owner" {
  equals "$(GH_KEYRING_BACKEND=security keyring get gh-readonly tvrmsmith)" stored-token
  contains "$(cat "$LOG")" "security find-generic-password -s gh-readonly -a tvrmsmith -w"
}

@test "macOS set passes the stdin token with -w and overwrites with -U" {
  printf 'new-token' | GH_KEYRING_BACKEND=security keyring set gh-prwrite some-org "GitHub PR-write PAT"
  contains "$(cat "$LOG")" "security add-generic-password -U -s gh-prwrite -a some-org -w new-token -D GitHub PR-write PAT"
}

@test "Linux get reads the Secret Service by the same service and owner" {
  equals "$(GH_KEYRING_BACKEND=secret-tool keyring get gh-readonly tvrmsmith)" stored-token
  contains "$(cat "$LOG")" "secret-tool lookup service gh-readonly account tvrmsmith"
}

@test "Linux set keeps the token off argv and feeds it on stdin" {
  printf 'new-token' | GH_KEYRING_BACKEND=secret-tool keyring set gh-readonly some-org "GitHub read-only PAT"
  log="$(cat "$LOG")"
  contains "$log" "secret-tool store --label=GitHub read-only PAT (gh-readonly/some-org) service gh-readonly account some-org <stdin:new-token>"
}

@test "with no override the backend follows uname" {
  printf '#!/bin/bash\necho Darwin\n' > "$BIN/uname"; chmod +x "$BIN/uname"
  keyring has gh-readonly x
  contains "$(cat "$LOG")" "security find-generic-password"

  : > "$LOG"
  printf '#!/bin/bash\necho Linux\n' > "$BIN/uname"
  keyring has gh-readonly x
  contains "$(cat "$LOG")" "secret-tool lookup"
}

# A Linux sandbox gets dot-local/bin copied in with no libsecret. The shim must
# treat that as "no token here" and fall through, not die.
@test "a missing backend is a plain miss, not an error" {
  rm "$BIN/secret-tool"
  run env GH_KEYRING_BACKEND=secret-tool PATH="$BIN:/usr/bin:/bin" bash "$KEYRING" get gh-readonly x
  equals "$status" 1
  is_empty "$output"
}

@test "a missing argument is a usage error" {
  run keyring get gh-readonly
  equals "$status" 2
  contains "$output" "usage: gh-keyring"
}

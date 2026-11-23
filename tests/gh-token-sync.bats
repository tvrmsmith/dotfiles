load helpers/assert

# gh-token-sync reads 1Password through `op` and writes through gh-keyring, so a
# stub `op` and a file-backed stub `security` cover it with no network, no
# 1Password and no real keychain.
SYNC="${BATS_TEST_DIRNAME}/../dot-local/bin/gh-token-sync"
export GH_KEYRING_BACKEND=security

setup() {
  TMP="$(mktemp -d)"
  BIN="$TMP/bin"
  STORE="$TMP/store"
  mkdir -p "$BIN" "$STORE"
  # op read <ref>: answers from $TMP/vault/<ref with / as _>, counting each read.
  cat > "$BIN/op" <<STUB
#!/bin/bash
ref="\${@: -1}"
echo "\$ref" >> "$TMP/op-reads"
f="$TMP/vault/\$(printf '%s' "\$ref" | tr '/ ' '__')"
[ -f "\$f" ] || exit 1
cat "\$f"
STUB
  # security: find-generic-password -s svc -a acct -w / add-generic-password -U -s svc -a acct -w token
  cat > "$BIN/security" <<STUB
#!/bin/bash
cmd="\$1"; shift; svc=""; acct=""; pw=""
while [ \$# -gt 0 ]; do case "\$1" in -s) svc="\$2"; shift 2 ;; -a) acct="\$2"; shift 2 ;; -w) pw="\${2:-}"; shift; [ -n "\$pw" ] && shift ;; *) shift ;; esac; done
f="$STORE/\$svc.\$acct"
case "\$cmd" in
  find-generic-password) [ -f "\$f" ] && cat "\$f" ;;
  add-generic-password) printf '%s' "\$pw" > "\$f"; echo "\$acct" >> "$TMP/writes" ;;
esac
STUB
  chmod +x "$BIN"/*
  mkdir -p "$TMP/vault"
  export PATH="$BIN:$PATH" OP_SERVICE_ACCOUNT_TOKEN=sa-token GH_TOKEN_SYNC_MAP="$TMP/tokens"
}

teardown() { rm -rf "$TMP"; }

vault() { printf '%s' "$2" > "$TMP/vault/$(printf '%s' "$1" | tr '/ ' '__')"; }

@test "each owner's token lands in the keyring under gh-token" {
  vault "op://Vault A/Item one/token" personal-token
  vault "op://Vault A/Item two/token" work-token
  cat > "$TMP/tokens" <<MAP
# owner  ref
user-one             op://Vault A/Item one/token
user-two             op://Vault A/Item two/token
some-work-org        op://Vault A/Item two/token
MAP
  out="$(bash "$SYNC" 2>&1)"
  equals "$(cat "$STORE/gh-token.user-one")" personal-token
  equals "$(cat "$STORE/gh-token.user-two")" work-token
  equals "$(cat "$STORE/gh-token.some-work-org")" work-token
  # A shared reference is read once.
  equals "$(wc -l < "$TMP/op-reads" | tr -d ' ')" 2
  lacks "$out" personal-token
  lacks "$out" work-token
}

@test "an unchanged token writes nothing, a rotated one is replaced" {
  vault "op://V/I/token" first
  echo "tvrmsmith op://V/I/token" > "$TMP/tokens"
  bash "$SYNC" >/dev/null 2>&1
  bash "$SYNC" >/dev/null 2>&1
  equals "$(wc -l < "$TMP/writes" | tr -d ' ')" 1

  vault "op://V/I/token" second
  out="$(bash "$SYNC" 2>&1)"
  contains "$out" "updated tvrmsmith"
  equals "$(cat "$STORE/gh-token.tvrmsmith")" second
}

@test "the timer's credential supplies the service account token" {
  unset OP_SERVICE_ACCOUNT_TOKEN
  mkdir -p "$TMP/creds"
  printf 'sa-from-cred\n' > "$TMP/creds/op-service-account"
  # op stub that only answers when the service account token arrived.
  cat > "$BIN/op" <<'STUB'
#!/bin/bash
[ "$OP_SERVICE_ACCOUNT_TOKEN" = sa-from-cred ] && printf tok
STUB
  echo "tvrmsmith op://V/I/token" > "$TMP/tokens"
  CREDENTIALS_DIRECTORY="$TMP/creds" bash "$SYNC" >/dev/null 2>&1
  equals "$(cat "$STORE/gh-token.tvrmsmith")" tok
}

@test "no service account token stops before reading anything" {
  unset OP_SERVICE_ACCOUNT_TOKEN
  echo "tvrmsmith op://V/I/token" > "$TMP/tokens"
  run bash "$SYNC"
  equals "$status" 1
  contains "$output" "no service account token"
  [ ! -e "$TMP/op-reads" ] || { echo "op was called" >&2; exit 1; }
}

@test "a failed read leaves the old token and fails the run" {
  printf 'old' > "$STORE/gh-token.tvrmsmith"
  echo "tvrmsmith op://V/missing/token" > "$TMP/tokens"
  run bash "$SYNC"
  equals "$status" 1
  equals "$(cat "$STORE/gh-token.tvrmsmith")" old
}

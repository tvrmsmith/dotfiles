load helpers/assert

SCRIPT="${BATS_TEST_DIRNAME}/../dot-local/bin/agent-decision-log"

setup() {
  TMP="$(mktemp -d)"
  # bats inherits the real XDG_STATE_HOME, and the sweep deletes files, so every
  # test points it at the sandbox.
  export XDG_STATE_HOME="$TMP/state"
  DIR="$TMP/state/agent-decision-logs"
  LOG="$DIR/afk-s1.tsv"
}
teardown() { rm -rf "$TMP"; }

@test "a write creates the log with a header and one well-formed row" {
  out="$(bash "$SCRIPT" afk-s1 frame "chose X" "because Y" "commit abc123" done)"
  is_empty "$out"
  equals "$(sed -n 1p "$LOG")" "$(printf 'ts\tphase\tdecision\twhy\tevidence\tresult')"
  IFS=$'\t' read -r ts phase decision why evidence result <<< "$(sed -n 2p "$LOG")"
  equals "$phase|$decision|$why|$evidence|$result" "frame|chose X|because Y|commit abc123|done"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || { printf 'bad ts: %s\n' "$ts" >&2; exit 1; }
}

@test "a second write appends to the same log" {
  bash "$SCRIPT" afk-s1 frame "chose X" "because Y" "commit abc123" done
  bash "$SCRIPT" afk-s1 build "chose Z" "because W" "commit def456" done
  equals "$(wc -l < "$LOG" | tr -d ' ')" "3"
}

@test "--path prints the log path and creates nothing" {
  out="$(bash "$SCRIPT" --path afk-s1)"
  equals "$out" "$LOG"
  [ ! -e "$DIR" ] || { printf 'expected %s to stay absent\n' "$DIR" >&2; exit 1; }
}

@test "--path falls back to HOME/.local/state without XDG_STATE_HOME" {
  unset XDG_STATE_HOME
  export HOME="$TMP/home"
  out="$(bash "$SCRIPT" --path afk-s1)"
  equals "$out" "$TMP/home/.local/state/agent-decision-logs/afk-s1.tsv"
}

@test "a write sweeps tsv logs older than 30 days and nothing else" {
  mkdir -p "$DIR"
  touch -t "$(date -v-31d +%Y%m%d%H%M)" "$DIR/old.tsv" "$DIR/old.txt"
  touch -t "$(date -v-29d +%Y%m%d%H%M)" "$DIR/recent.tsv"
  bash "$SCRIPT" afk-s1 frame a b c d
  [ ! -e "$DIR/old.tsv" ] || { printf 'old.tsv survived the sweep\n' >&2; exit 1; }
  [ -e "$DIR/recent.tsv" ] || { printf 'recent.tsv was swept\n' >&2; exit 1; }
  [ -e "$DIR/old.txt" ] || { printf 'old.txt was swept\n' >&2; exit 1; }
  [ -e "$LOG" ] || { printf 'the new log is missing\n' >&2; exit 1; }
}

@test "cell sanitising is delegated to log.sh" {
  bash "$SCRIPT" afk-s1 frame a b c -1
  IFS=$'\t' read -r _ _ _ _ _ result <<< "$(sed -n 2p "$LOG")"
  equals "$result" "'-1"
}

@test "a bad name exits 1 and writes nothing" {
  for bad in afk- ../x a/b; do
    run bash "$SCRIPT" "$bad" frame a b c d
    equals "$status" "1"
  done
  run bash "$SCRIPT" --path ../x
  equals "$status" "1"
  equals "$(find "$TMP/state" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
}

@test "a wrong argument count prints usage and exits 1" {
  run bash "$SCRIPT" afk-s1 frame a b c
  equals "$status" "1"
  contains "$output" "usage"
}

@test "it works when reached through a symlink" {
  mkdir -p "$TMP/bin"
  ln -s "$(cd "$(dirname "$SCRIPT")" && pwd -P)/agent-decision-log" "$TMP/bin/agent-decision-log"
  bash "$TMP/bin/agent-decision-log" afk-s1 frame a b c d
  [ -e "$LOG" ] || { printf 'the row did not land in %s\n' "$LOG" >&2; exit 1; }
}

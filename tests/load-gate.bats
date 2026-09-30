load helpers/assert

HOOK="${BATS_TEST_DIRNAME}/../dot-claude/hooks/load-gate.sh"

setup() {
  TMP="$(mktemp -d)"
  ORIG_PATH="$PATH"
  # A fake sysctl reads the load from a file, one line per call, so a test can
  # script load falling across polls. The last line repeats once they run out.
  LOADS="$TMP/loads"
  CALLS="$TMP/calls"
  : > "$CALLS"
  cat > "$TMP/sysctl" <<SH
#!/bin/bash
case "\$2" in
  hw.ncpu) echo 4 ;;
  vm.loadavg)
    n=\$(( \$(wc -l < "$CALLS") + 1 ))
    echo x >> "$CALLS"
    line=\$(sed -n "\${n}p" "$LOADS")
    [ -n "\$line" ] || line=\$(tail -1 "$LOADS")
    echo "{ \$line 1.00 1.00 }"
    ;;
esac
SH
  chmod +x "$TMP/sysctl"
  export PATH="$TMP:$PATH"
  export LOAD_GATE_INTERVAL=1 LOAD_GATE_MAX_WAIT=2
}
teardown() { PATH="$ORIG_PATH"; rm -rf "$TMP"; }

# Pipes a Bash payload carrying command $1.
gate() {
  jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$HOOK"
}

polls() { wc -l < "$CALLS" | tr -d ' '; }

@test "a test command under the core count runs at once, silently" {
  echo 2.50 > "$LOADS"
  out="$(gate 'dotnet test src/App.Tests')"
  is_empty "$out"
}

@test "a test command waits until load falls to the core count" {
  printf '9.00\n6.00\n3.00\n' > "$LOADS"
  out="$(gate 'cd api && pnpm test')"
  contains "$out" "fell from 9.00 to 3.00 on 4 cores"
  equals "$(polls)" 3
}

@test "the wait is capped, and the tests then run with a warning" {
  echo 20.00 > "$LOADS"
  out="$(gate 'go test ./...')"
  contains "$out" "stayed above 4 cores"
  contains "$out" "running the tests anyway"
}

@test "a command that is not a test run is never held" {
  echo 20.00 > "$LOADS"
  out="$(gate 'git status')"
  is_empty "$out"
  equals "$(polls)" 0
}

@test "a runner named in an argument, not run, is not held" {
  echo 20.00 > "$LOADS"
  out="$(gate 'grep -rn "go test" docs/')"
  is_empty "$out"
}

@test "runners behind env assignments and wrappers are held" {
  export LOAD_GATE_MAX_WAIT=1
  echo 20.00 > "$LOADS"
  out="$(gate 'CI=1 npx vitest run')"
  contains "$out" "load-gate"
  out="$(gate 'uv run pytest -q')"
  contains "$out" "load-gate"
  out="$(gate 'npm run test:unit')"
  contains "$out" "load-gate"
}

load helpers/assert

HOOK="${BATS_TEST_DIRNAME}/../dot-claude/hooks/load-gate.sh"

setup() {
  TMP="$(mktemp -d)"
  ORIG_PATH="$PATH"
  # Fake memory_pressure and top read scripted readings, one line per call, so
  # a test can script the machine freeing up across polls. The last line
  # repeats once they run out. Each file line is "<free mem %> <idle cpu %>".
  READINGS="$TMP/readings"
  CALLS="$TMP/calls"
  : > "$CALLS"
  cat > "$TMP/reading" <<SH
#!/bin/bash
n=\$(grep -c . "$CALLS" || true)
line=\$(sed -n "\$(( n + 1 ))p" "$READINGS")
[ -n "\$line" ] || line=\$(tail -1 "$READINGS")
printf '%s\n' "\$line"
SH
  cat > "$TMP/memory_pressure" <<SH
#!/bin/bash
mem=\$("$TMP/reading" | awk '{print \$1}')
echo "System-wide memory free percentage: \${mem}%"
SH
  # top is read after memory_pressure in each poll, so it advances the counter.
  cat > "$TMP/top" <<SH
#!/bin/bash
cpu=\$("$TMP/reading" | awk '{print \$2}')
echo x >> "$CALLS"
echo "CPU usage: 50.00% user, 10.00% sys, 90.00% idle"
echo "CPU usage: 10.00% user, 10.00% sys, \${cpu}% idle"
SH
  chmod +x "$TMP/reading" "$TMP/memory_pressure" "$TMP/top"
  export PATH="$TMP:$PATH"
  export LOAD_GATE_INTERVAL=1 LOAD_GATE_MAX_WAIT=2
}
teardown() { PATH="$ORIG_PATH"; rm -rf "$TMP"; }

# Pipes a Bash payload carrying command $1.
gate() {
  jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | bash "$HOOK"
}

polls() { grep -c . "$CALLS" || true; }

@test "a test command on a healthy machine runs at once, silently" {
  echo "46 37" > "$READINGS"
  out="$(gate 'dotnet test src/App.Tests')"
  is_empty "$out"
}

@test "low free memory holds the tests until it recovers" {
  printf '8 50\n12 50\n35 50\n' > "$READINGS"
  out="$(gate 'cd api && pnpm test')"
  contains "$out" "until the machine freed up"
  contains "$out" "was memory 8% free"
  contains "$out" "now memory 35% free"
  equals "$(polls)" 3
}

@test "low idle CPU holds the tests on its own" {
  printf '60 4\n60 40\n' > "$READINGS"
  out="$(gate 'go test ./...')"
  contains "$out" "CPU 4% idle"
  contains "$out" "until the machine freed up"
}

@test "the wait is capped, and the tests then run with a warning" {
  echo "5 2" > "$READINGS"
  out="$(gate 'go test ./...')"
  contains "$out" "stayed busy"
  contains "$out" "running the tests anyway"
}

@test "an unreadable signal never holds the tests" {
  echo "46 37" > "$READINGS"
  # Replaced rather than deleted, since deleting would expose the real one.
  printf '#!/bin/bash\nexit 1\n' > "$TMP/memory_pressure"
  out="$(gate 'bats tests/')"
  is_empty "$out"
}

@test "a command that is not a test run is never held" {
  echo "5 2" > "$READINGS"
  out="$(gate 'git status')"
  is_empty "$out"
  equals "$(polls)" 0
}

@test "a runner named in an argument, not run, is not held" {
  echo "5 2" > "$READINGS"
  out="$(gate 'grep -rn "go test" docs/')"
  is_empty "$out"
}

@test "runners behind env assignments and wrappers are held" {
  export LOAD_GATE_MAX_WAIT=1
  echo "5 2" > "$READINGS"
  out="$(gate 'CI=1 npx vitest run')"
  contains "$out" "load-gate"
  out="$(gate 'uv run pytest -q')"
  contains "$out" "load-gate"
  out="$(gate 'npm run test:unit')"
  contains "$out" "load-gate"
}

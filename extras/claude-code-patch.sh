#!/usr/bin/env bash
# Patch Claude Code binary to allow skillOverrides for plugin-scoped skills.
# Re-run after each Claude Code update.
#
# The stock skill override check hardcodes source==="plugin" to return "on",
# bypassing skillOverrides. This patch changes the match string so
# skillOverrides apply to all skill sources.
#
# Matching strategy: use a semantically unique pattern that captures the
# override-bypass logic rather than relying on minified identifiers.

set -euo pipefail

VERSIONS_DIR="$HOME/.local/share/claude/versions"
BINARY=$(ls -t "$VERSIONS_DIR"/* 2>/dev/null | head -1)

if [[ -z "$BINARY" ]]; then
  echo "No Claude Code binary found in $VERSIONS_DIR" >&2
  exit 1
fi

VERSION=$(basename "$BINARY")
echo "Target: $BINARY (v$VERSION)"

# Extract entitlements before patching (re-sign would strip them)
ENTITLEMENTS=$(mktemp /tmp/claude-entitlements.XXXXXX.plist)
codesign -d --entitlements "$ENTITLEMENTS" --xml "$BINARY" 2>/dev/null
trap 'rm -f "$ENTITLEMENTS"' EXIT

PATCH_RC=0
python3 - "$BINARY" <<'PYEOF' || PATCH_RC=$?
import sys, shutil, os

binary_path = sys.argv[1]

with open(binary_path, "rb") as f:
    data = f.read()

# Match the semantic pattern: source==="plugin" immediately followed by
# )return"on" — this is the override-bypass return. Unique across versions
# regardless of minified function/variable names.
NEEDLE  = b'source==="plugin")return"on"'
REPLACE = b'source==="plUG!N")return"on"'

assert len(NEEDLE) == len(REPLACE), "length mismatch"

# Check if already patched
if REPLACE in data and NEEDLE not in data:
    print("Already patched.")
    sys.exit(2)

count = data.count(NEEDLE)
if count == 0:
    print("Pattern not found — binary layout may have changed.", file=sys.stderr)
    sys.exit(3)
if count > 1:
    print(f"Found {count} matches — ambiguous. Aborting.", file=sys.stderr)
    start = 0
    for i in range(count):
        pos = data.find(NEEDLE, start)
        ctx = data[max(0, pos - 60):pos + 60]
        print(f"  [{i}] offset {pos}: ...{ctx.decode('utf-8', errors='replace')}...", file=sys.stderr)
        start = pos + 1
    sys.exit(4)

pos = data.find(NEEDLE)
ctx = data[max(0, pos - 50):pos + len(NEEDLE) + 50].decode("utf-8", errors="replace")
print(f"Match at offset {pos}:")
print(f"  ...{ctx}...")

# Backup
backup = binary_path + ".bak"
if not os.path.exists(backup):
    shutil.copy2(binary_path, backup)
    print(f"Backup: {backup}")

# Patch
patched = data[:pos] + REPLACE + data[pos + len(NEEDLE):]
with open(binary_path, "wb") as f:
    f.write(patched)

print("Done. skillOverrides now applies to plugin skills.")
PYEOF

if [[ $PATCH_RC -eq 0 ]]; then
  echo "Re-signing binary with entitlements..."
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BINARY"
  echo "Signature valid. Entitlements preserved."
elif [[ $PATCH_RC -eq 2 ]]; then
  : # already patched, no re-sign needed
else
  exit "$PATCH_RC"
fi

#!/usr/bin/env bash
# Patch Claude Code binary to allow skillOverrides for plugin-scoped skills.
# Platform-agnostic: handles macOS codesigning when available, skips on Linux.
# Re-run after each Claude Code update.

set -euo pipefail

VERSIONS_DIR="$HOME/.local/share/claude/versions"
BINARY=$(ls -t "$VERSIONS_DIR"/* 2>/dev/null | head -1)

if [[ -z "$BINARY" ]]; then
  echo "No Claude Code binary found in $VERSIONS_DIR" >&2
  exit 1
fi

VERSION=$(basename "$BINARY")
echo "Target: $BINARY (v$VERSION)"

# Extract entitlements on macOS (codesign would strip them)
ENTITLEMENTS=""
if command -v codesign &>/dev/null; then
  ENTITLEMENTS=$(mktemp /tmp/claude-entitlements.XXXXXX.plist)
  codesign -d --entitlements "$ENTITLEMENTS" --xml "$BINARY" 2>/dev/null
  trap 'rm -f "$ENTITLEMENTS"' EXIT
fi

PATCH_RC=0
python3 - "$BINARY" <<'PYEOF' || PATCH_RC=$?
import sys, shutil, os

binary_path = sys.argv[1]

with open(binary_path, "rb") as f:
    data = f.read()

PATCHES = [
    {
        "name": "skillOverrides bypass",
        "needle":  b'source==="plugin")return"on"',
        "replace": b'source==="plUG!N")return"on"',
    },
    {
        "name": "/skills UI state override",
        "needle":  b'source==="plugin")return{value:"on",source:"plugin"}',
        "replace": b'source==="plUG!N")return{value:"on",source:"plugin"}',
    },
]

for p in PATCHES:
    assert len(p["needle"]) == len(p["replace"]), f'{p["name"]}: length mismatch'

all_patched = all(
    p["replace"] in data and p["needle"] not in data for p in PATCHES
)
if all_patched:
    print("Already patched.")
    sys.exit(2)

backup = binary_path + ".bak"
if not os.path.exists(backup):
    shutil.copy2(binary_path, backup)
    print(f"Backup: {backup}")

applied = 0
for p in PATCHES:
    name = p["name"]
    needle = p["needle"]
    replace = p["replace"]

    if replace in data and needle not in data:
        print(f"[{name}] already patched, skipping.")
        continue

    count = data.count(needle)
    if count == 0:
        print(f"[{name}] pattern not found — binary layout may have changed.", file=sys.stderr)
        sys.exit(3)
    if count > 1:
        print(f"[{name}] found {count} matches — ambiguous. Aborting.", file=sys.stderr)
        start = 0
        for i in range(count):
            pos = data.find(needle, start)
            ctx = data[max(0, pos - 60):pos + 60]
            print(f"  [{i}] offset {pos}: ...{ctx.decode('utf-8', errors='replace')}...", file=sys.stderr)
            start = pos + 1
        sys.exit(4)

    pos = data.find(needle)
    ctx = data[max(0, pos - 50):pos + len(needle) + 50].decode("utf-8", errors="replace")
    print(f"[{name}] match at offset {pos}:")
    print(f"  ...{ctx}...")

    data = data[:pos] + replace + data[pos + len(needle):]
    applied += 1

with open(binary_path, "wb") as f:
    f.write(data)

print(f"Done. Applied {applied} patch(es). skillOverrides + /skills UI fixed for plugin skills.")
PYEOF

case $PATCH_RC in
  0) # Newly patched — re-sign on macOS
    if [[ -n "$ENTITLEMENTS" ]]; then
      echo "Re-signing binary with entitlements..."
      codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BINARY"
      echo "Signature valid. Entitlements preserved."
    fi
    ;;
  2) ;; # Already patched — nothing to do
  *) exit "$PATCH_RC" ;;
esac

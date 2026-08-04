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

if ! command -v python3 &>/dev/null; then
  echo "python3 is required (Arch: pacman -S python)" >&2
  exit 1
fi

VERSIONS_DIR="$HOME/.local/share/claude/versions"
# Newest version, excluding the .bak this script leaves next to each binary.
# `command ls` because an interactive `ls` alias (eza) rejects BSD-style flags.
BINARY=$(command ls -t "$VERSIONS_DIR"/* 2>/dev/null | grep -v '\.bak$' | head -1)

if [[ -z "$BINARY" || ! -f "$BINARY" || ! -x "$BINARY" ]]; then
  echo "No Claude Code binary found in $VERSIONS_DIR" >&2
  exit 1
fi

VERSION=$(basename "$BINARY")
echo "Target: $BINARY (v$VERSION)"

# Extract entitlements before patching (re-sign would strip them). macOS only —
# on Linux there is no codesign and nothing to preserve.
# BSD mktemp only substitutes trailing Xs, so a `.plist` after them is taken
# literally — same path every run, and "mkstemp failed ... File exists" the
# moment one is left behind. Make a temp dir, name the file inside it.
ENTITLEMENTS=""
if command -v codesign &>/dev/null; then
  ENTITLEMENTS_DIR=$(mktemp -d /tmp/claude-entitlements.XXXXXX)
  trap 'rm -rf "$ENTITLEMENTS_DIR"' EXIT
  ENTITLEMENTS="$ENTITLEMENTS_DIR/entitlements.plist"
  codesign -d --entitlements "$ENTITLEMENTS" --xml "$BINARY" 2>/dev/null
fi

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

# Patch. Write a sibling and rename over the target instead of writing in
# place: Linux refuses to open a currently-executing binary for writing
# (ETXTBSY), and a rename swaps the directory entry, not the running inode.
patched = data[:pos] + REPLACE + data[pos + len(NEEDLE):]
tmp_path = binary_path + ".patched.tmp"
with open(tmp_path, "wb") as f:
    f.write(patched)
shutil.copymode(binary_path, tmp_path)
os.replace(tmp_path, binary_path)

print("Done. skillOverrides now applies to plugin skills.")
PYEOF

if [[ $PATCH_RC -eq 0 && -n "$ENTITLEMENTS" ]]; then
  echo "Re-signing binary with entitlements..."
  codesign --force --sign - --entitlements "$ENTITLEMENTS" "$BINARY"
  echo "Signature valid. Entitlements preserved."
elif [[ $PATCH_RC -eq 0 || $PATCH_RC -eq 2 ]]; then
  : # patched on Linux (nothing to re-sign), or already patched
else
  exit "$PATCH_RC"
fi

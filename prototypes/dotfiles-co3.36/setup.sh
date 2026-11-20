#!/usr/bin/env bash
# Builds a scratch target for the co3.36 prototype and prints the command that
# starts it. Nothing here touches a real repository or tracker.
#
#   prototypes/dotfiles-co3.36/setup.sh [goal]
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
goal=${1:-"Add a --dry-run flag to a small CLI that renames photos by EXIF date"}
grilling=${GRILLING_SKILL:-$HOME/dev/personal/mattpocock-skills/skills/productivity/grilling}
[ -f "$grilling/SKILL.md" ] || { echo "no grilling skill at $grilling; set GRILLING_SKILL" >&2; exit 1; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/co3-36.XXXX")
git init -q --bare -b main "$scratch/origin.git"
git clone -q "$scratch/origin.git" "$scratch/repo" 2>/dev/null
cd "$scratch/repo"
mkdir -p .archon/workflows/proto .claude/skills
cp -R "$here/workflows/." .archon/workflows/proto/
ln -s "$grilling" .claude/skills/grilling
echo "co3.36 prototype target" > README
git add -A
git commit -qm init
git push -q origin main

mkdir "$scratch/tracker"
cd "$scratch/tracker"
git init -q
BD_NON_INTERACTIVE=1 bd init --prefix px >/dev/null 2>&1

cat <<EOF
Scratch target: $scratch

Start it (attached, so the first gate's notice prints here):
  cd $scratch/repo && archon workflow run plan-epic \\
    --input goal='$goal' \\
    --input beads_dir=$scratch/tracker/.beads

Answer gates in the console (archon serve) or:
  archon workflow attention
  archon workflow answer <run> --occurrence <id> --choose <option> --text '...'

Watch the chain:  wave-status <wave run id>
Tracker:          BEADS_DIR=$scratch/tracker/.beads bd list --all
EOF

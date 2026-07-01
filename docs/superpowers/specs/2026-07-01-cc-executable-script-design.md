# cc executable script (Superset custom-agent launcher)

**Date:** 2026-07-01
**Status:** Approved design

## Problem

`cc` is a shell alias in `dot-zshrc`:

```
alias claude-patch='$DEV_PERSONAL/dotfiles/extras/claude-code-patch.sh'
alias cc='claude-patch; claude --dangerously-skip-permissions'
```

Superset (`~/dev/personal/superset`) launches coding agents as **custom terminal
agents**: each agent has a `command` string that Superset runs in a PTY
(`packages/shared/src/agent-definition.ts`; builtin claude uses
`command: "claude --dangerously-skip-permissions"`). A shell *alias* is not
resolvable as such a command — aliases only exist in interactive shells and are
not on `PATH`. So `cc` cannot be used as a Superset agent command today.

## Goal

Make `cc` a real executable on `PATH` so Superset (and any PATH-scanning tool)
can invoke it, while preserving the exact behavior of the current alias.

## Design

### New file: `dot-local/bin/cc`

Stow maps this to `~/.local/bin/cc`, already on `PATH`. Executable bash script,
self-contained (does not depend on `dot-zshrc` being sourced):

```bash
#!/usr/bin/env bash
# cc — launch Claude Code with the skillOverrides patch applied, skipping
# permission prompts. Executable form of the former `cc` zsh alias so PATH
# scanning tools (e.g. Superset custom terminal agents) can discover it.
set -euo pipefail

# Resolve this script's real path through the stow symlink (BSD readlink has no
# -f), then derive repo root: dot-local/bin/cc -> repo root.
src="${BASH_SOURCE[0]}"
while [ -h "$src" ]; do
  dir="$(cd -P "$(dirname "$src")" && pwd)"
  src="$(readlink "$src")"
  [[ $src != /* ]] && src="$dir/$src"
done
repo_root="$(cd -P "$(dirname "$src")/../.." && pwd)"
patch="$repo_root/extras/claude-code-patch.sh"

# Patch is best-effort — mirror the alias's `;` (run claude even if patch fails).
[ -x "$patch" ] && "$patch" || true

# Parity with dot-zshrc default; ccwf overrides to 0 and still works.
export CLAUDE_CODE_DISABLE_WORKFLOWS="${CLAUDE_CODE_DISABLE_WORKFLOWS:-1}"

exec claude --dangerously-skip-permissions "$@"
```

Notes:
- The symlink-walk resolves the relative stow symlink so `repo_root` points at
  the real dotfiles checkout, and works when run in-place (no symlink) too. Uses
  no `readlink -f` (absent on BSD/macOS).
- `exec` replaces the shell so signals/PTY behave; `"$@"` forwards Superset's
  prompt (argv transport, matching the builtin claude agent).
- Patch runs on every launch, same as the alias.

### `dot-zshrc` changes

- **Remove** the `cc` alias (line 142). The script becomes the single source;
  interactive shells resolve `cc` via `PATH`.
- **Keep** `claude-patch` alias, `cca` alias (`cc agents`), and the `ccwf`
  function — all call `cc`, which now resolves via `PATH`. `ccwf` still exports
  `CLAUDE_CODE_DISABLE_WORKFLOWS=0` before calling `cc`; the script honors the
  already-set value.

### Superset side (out of repo, documented only)

In Superset, add a custom terminal agent with `command: cc` and the default argv
prompt transport. No dotfiles change required for this; noted for completeness.

## Testing

- `~/.local/bin/cc` is executable and on `PATH` after `./install.sh`.
- `cc --version` (or `cc` with no args) launches Claude Code after running the
  patch.
- `command -v cc` resolves to `~/.local/bin/cc` in a fresh interactive shell (no
  alias shadowing).
- `cca` and `ccwf` still function.

## Out of scope

- Converting `cca` / `ccwf` to standalone executables.
- Any change to the patch script itself.

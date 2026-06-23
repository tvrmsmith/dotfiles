# mysbx — sbx-shaped drop-in wrapper

**Date:** 2026-06-23
**Status:** Approved design, pending implementation plan

## Problem

The current Docker sandbox helpers (`dsbx-cc`, `dsbx-omp`, `dsbx-ruby-cc`, plus
`dsbx-build`/`check`/`update`/`omp-build`/`omp-clean`) are zsh **functions** sourced
only by the interactive rc. They do create-time setup the bare `sbx` binary does
not: 1Password secret sync, kit selection, helper bind mounts (gcloud ADC, Claude
plugins, dotfiles, per-sandbox state), git-worktree source mounting, and naming.

Two motivations to restructure:

1. **`--clone` support.** `sbx create --clone` runs the agent on an in-container
   clone of the host repo (commits retrieved via a `sandbox-<name>` git remote).
   The current helpers always bind-mount cwd; there is no clone passthrough. The
   `sbx` GUI/TUI cannot do clone either, so the CLI wrapper is the only path.
2. **Reuse across other products.** Other products are gaining Docker-sandbox
   support and expose a *configurable sbx binary path*. Pointing them at our
   wrapper transparently gives them our customizations — but only if the wrapper
   is a real executable that behaves exactly like `sbx`, not a shell function.

This design replaces the `dsbx-*` functions with a single standalone executable,
`mysbx`, that **is** `sbx` plus our augmentation, and rebrands all helpers
`dsbx` → `mysbx`.

## Goals

- `mysbx` is a transparent, sbx-shaped drop-in: external products set their
  sbx-path to it and get our customizations with zero awareness of internals.
- Full rebrand `dsbx` → `mysbx` (commands, executable, internal helpers, file
  names, config dir, state dir, log). Existing `dsbx` sandboxes and state are
  abandoned (no migration). `nono-*` is untouched.
- Add `--clone` support via faithful passthrough.
- Self-contained: works under a minimal environment (no reliance on the
  interactive shell having sourced anything).

## Non-goals

- No clone/bind mode-mismatch detection or marker files. `mysbx create` is
  faithful to `sbx create` (errors on duplicate name); the interactive all-in-one
  path requires explicit `--recreate` to switch a sandbox's mode. `sbx ls --json`
  does not expose clone-ness, so there is nothing to reconcile against.
- No GUI/TUI work. The `sbx` TUI remains usable as a read-only dashboard over
  CLI-created sandboxes.

## Architecture

### Two augmentation tiers

- **Universal** — applies to any caller, including external products, with no
  preset: dir-aware 1Password secret sync, helper bind mounts, `--clone`
  handling.
- **Preset** — our ergonomic layer, opted in via `--preset cc|ruby-cc|omp`:
  agent default + kit bundle + prefix naming (`_mysbx_name`) + template.

External products call e.g. `mysbx create claude .` and receive only the
universal tier — the sandbox name stays the sbx default (or a product-supplied
`--name`), keeping the wrapper transparent. Our interactive functions pass
`--preset`, opting into the full tier.

### Dispatch

`mysbx <arg1> ...`:

- `create` → intercept. Parse `--preset` and `--clone` (our flags), apply
  universal augmentation, and if a preset is given, add kits + prefix naming +
  template. Then invoke the real `sbx create` with the assembled arguments,
  including `--clone` when requested.
- `run` / `exec` → TTL-gated secret resync (as today), then forward to real sbx.
- Custom verbs (`build`, `check`, `update`, `omp-build`, `omp-clean`,
  `secrets-sync`) → handled locally; never forwarded.
- **Anything else → `exec $REAL_SBX "$@"` verbatim.** Forward-compatible with
  future sbx verbs; no maintained mirror of sbx's verb list.

Dispatch is unambiguous: presets are a flag, not a positional, so `mysbx`'s first
arg is always either a known sbx/custom verb or forwarded as-is.

### Real-sbx resolution

`REAL_SBX` from config, else `command -v sbx`. Safe from recursion because the
wrapper is named `mysbx` (distinct from `sbx`). Guard: if the resolved path
resolves back to the wrapper itself, abort with an error.

### Config

Loaded from `~/.config/mysbx/config` (stow-managed via `dot-config/mysbx/`) if
present; **environment variables override** (each setting via
`: ${VAR:=<config-or-default>}`). Settings: `DEV_PERSONAL`, 1Password token
paths (work + personal GitHub, Atlassian), `JIRA_USERNAME`, `REAL_SBX`, XDG
dirs. Sourced shell syntax.

This decouples the wrapper from the interactive shell: when a product spawns it
under a minimal env (launchd/app context with none of the usual exports), config
still resolves.

### Degradation policy

- **Hard-fail on secret sync failure.** If the GitHub secret cannot sync, abort
  `create` — git inside the sandbox would be broken, a silent and confusing
  failure. (Applies to external callers too: a sandbox without working git auth
  is not worth creating.)
- **Warn + continue** for non-critical augmentation (e.g. an absent optional
  helper-mount source). Log to the wrapper log; print a stderr warning.

## File layout (stow-managed)

| Path | Role |
| --- | --- |
| `dot-config/mysbx/config` → `~/.config/mysbx/config` | Settings; env overrides |
| `dot-local/bin/mysbx` → `~/.local/bin/mysbx` | `#!/usr/bin/env zsh` executable: load config → source core lib → dispatch |
| `extras/agent-sandboxing/lib/mysbx-core.zsh` | **Single source of truth**: config load, real-sbx resolve + self-guard, secret sync, helper mounts, naming, preset registry, create/run augmentation |
| `extras/agent-sandboxing/20-mysbx.zsh` | Interactive rc: sources core lib; defines thin `mysbx-cc/ruby-cc/omp` (call `mysbx ... --preset`) + `mysbx-build/check/update/omp-build/omp-clean` |

The core lib is sourced by both the executable and the interactive file — no
logic duplication. The interactive functions are thin: agent + preset selection
plus the all-in-one create-then-run convenience.

### Rename map (mechanical)

- Commands: `dsbx-*` → `mysbx-*`
- Internal helpers/vars: `_dsbx_*` / `_DSBX_*` → `_mysbx_*` / `_MYSBX_*`
- Files: `20-dsbx.zsh` → `20-mysbx.zsh`; new `lib/mysbx-core.zsh`
- State: `~/.local/state/dsbx` → `~/.local/state/mysbx`; `dsbx.log` → `mysbx.log`
- Config: new `~/.config/mysbx/config`
- Docs: `agent-sandboxing` skill (`.claude/skills/agent-sandboxing/SKILL.md`) and
  `CLAUDE.md` notes updated to `mysbx`
- `init.zsh` sources `20-mysbx.zsh`; `nono-*` untouched

## Interactive preset behavior

Preset functions keep today's all-in-one ergonomics:

- `mysbx-omp [flags/workspaces]` → create-if-needed + run (or `exec -p` in print
  mode), exactly like `dsbx-omp` today.
- Mode switch (bind ↔ clone) requires explicit `--recreate`: existing sandbox →
  reconnect/run; `--recreate` → tear down and recreate with the requested mode.
  No automatic detection (sbx exposes no clone state).

The preset registry maps `cc|ruby-cc|omp` → (agent, kit list, template), driving
both the interactive functions and the `--preset` flag.

## Clone support

`--clone` is parsed by `mysbx create` and forwarded to `sbx create --clone`.
Interactive functions accept it and pass it through. Helper bind mounts (ADC,
plugins, dotfiles, state) are still attached as additional read-only workspaces;
`--clone` only changes how the *primary* repo is provided (in-container clone vs
bind), so the universal augmentation is unaffected.

## Testing

**bats-core** (`brew install bats-core`). A stub `sbx` placed earlier on PATH
records its argv so tests assert the wrapper forwards/assembles correctly.

Coverage:

- Dispatch routing: `create` intercept, `run`/`exec` resync+forward, custom
  verbs handled locally, unknown verb forwarded verbatim.
- Config load: with/without config file; env-var override precedence.
- Real-sbx resolution + self-reference guard.
- `--clone` reaches `sbx create --clone`.
- Preset assembly: `--preset omp` produces expected agent + kits + name +
  template in the forwarded argv.
- Secret-sync hard-fail aborts `create`.

Manual: point a product's sbx-path at `mysbx` and run create/run; confirm
interactive `mysbx-omp` works; clone round-trip via the `sandbox-<name>` git
remote.

## Migration

None. Existing `dsbx` sandboxes and `~/.local/state/dsbx` are abandoned;
recreate via `mysbx-*` as needed. Old `dsbx-*` commands are removed once
`20-mysbx.zsh` replaces `20-dsbx.zsh`.

## Open implementation-time checks

- Exact `sbx create` flag/positional ordering for `--clone` combined with
  additional workspaces and `--kit`.
- Whether `run`/`exec` need `--name` resolution in the drop-in path or only the
  preset path.

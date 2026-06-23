# mysbx — sbx superset wrapper with smart-agent presets

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
   The current helpers always bind-mount cwd; there is no clone passthrough.
2. **Reuse across other products.** Other products (e.g. superset) are gaining
   Docker-sandbox support and let you configure the *full command* used to launch
   sandboxes/agents. Pointing them at our wrapper gives them our customizations —
   but only if the wrapper is a real executable that behaves like `sbx`, not a
   shell function.

This design replaces the `dsbx-*` functions with a single standalone executable,
`mysbx`, that is a **faithful superset of `sbx`**: it preserves sbx's verb-first
grammar exactly, and our augmentation is opted into by naming a **preset
"smart agent"** in the agent positional of `create`/`run`. A preset is an sbx
agent plus features: `cc`/`ruby-cc` expand to the `claude` agent, `omp` to the
omp agent, each adding kits, template, helper mounts, secrets, and naming. It
also rebrands all helpers `dsbx` → `mysbx`.

## Goals

- `mysbx` is a faithful sbx passthrough using identical grammar; augmentation is
  **opt-in** by naming a preset agent (`mysbx create cc .`). Any real sbx agent
  (`claude`, `codex`, …) passes through vanilla.
- Full rebrand `dsbx` → `mysbx` (commands, executable, internal helpers, file
  names, config dir, state dir, log). Existing `dsbx` sandboxes and state are
  abandoned (no migration). `nono-*` is untouched.
- Add `--clone` support via faithful passthrough.
- Self-contained: works under a minimal environment (no reliance on the
  interactive shell having sourced anything).

## Non-goals

- No clone/bind mode-mismatch detection or marker files. `mysbx create <preset>`
  is faithful to `sbx create` (errors on duplicate name); the interactive
  all-in-one path requires explicit `--recreate` to switch a sandbox's mode.
  `sbx ls --json` does not expose clone-ness, so there is nothing to reconcile.
- No default/inferred preset. A real agent name (`claude`, …) is vanilla sbx;
  there is no silent fallback that could produce a kit-less broken sandbox.
- No GUI/TUI work. The `sbx` TUI remains usable as a read-only dashboard over
  CLI-created sandboxes.

## Architecture

### Dispatch

Dispatch keys on the **verb** (`arg1`), preserving sbx's verb-first grammar.
`arg1` is always a verb — never a preset.

`mysbx <verb> …`:

- **Custom verbs** (`build`, `check`, `update`, `omp-build`, `omp-clean`,
  `secrets-sync`) → handled locally; never forwarded. These are mysbx-only.
- **`create` / `run`** → inspect the **agent positional**:
  - agent is a known preset (`cc` | `ruby-cc` | `omp`) → expand agent → real
    agent (`claude`/omp) and inject augmentation (secret sync, helper mounts,
    preset kits + template + `_mysbx_name` naming, `--clone` passthrough), then
    invoke real sbx. Faithful: errors on duplicate name (no create-if-needed
    skip).
  - agent is anything else (`claude`, `codex`, …) → vanilla forward.
- **`exec`** → TTL-gated secret resync, then forward verbatim. The sandbox is
  referenced by name (sbx grammar); see Naming for how the name is supplied.
- **Any other verb** → `exec $REAL_SBX "$@"` verbatim. Forward-compatible with
  future sbx verbs; no maintained verb mirror.

Key property: **augmentation is opt-in by naming a preset agent.**
`mysbx create cc .` is augmented; `mysbx create claude .` is vanilla sbx. Because
the grammar matches sbx exactly, any product that configures an sbx command/agent
slots the preset into the agent position with no special handling.

### Preset registry

Maps `cc | ruby-cc | omp` → (real agent, kit list, template). Drives both the
executable's create/run expansion and the interactive functions. Kit sets mirror
today's helpers (tooling + claude-code-patch + personal [+ atlassian off-personal]
for cc/ruby-cc; personal [+ atlassian] + omp for omp). Preset names must not
collide with real sbx agent names (`claude`, `codex`, `gemini`, …).

### All-in-one launch — interactive only

The create-if-needed + run/exec convenience lives **only** in the `mysbx-*` shell
functions, implemented via the core lib. The executable is purely sbx-grammar
(verb-first) / passthrough. Interactive functions check existence and
reconnect/run; `--recreate` switches a sandbox's mode (e.g. bind ↔ clone).

### Real-sbx resolution

`REAL_SBX` from config, else `command -v sbx` (safe — wrapper is named `mysbx`,
distinct from `sbx`). Guard: if the resolved path resolves back to the wrapper
itself, abort with an error.

### Config

Loaded from `~/.config/mysbx/config` (stow-managed via `dot-config/mysbx/`) if
present; **environment variables override** (each setting via
`: ${VAR:=<config-or-default>}`). Settings: `DEV_PERSONAL`, 1Password token
paths (work + personal GitHub, Atlassian), `JIRA_USERNAME`, `REAL_SBX`, XDG
dirs. Sourced shell syntax.

Decouples the wrapper from the interactive shell: when a product spawns it under
a minimal env, config still resolves. (Note: superset launches via an
interactive PTY shell, so it *does* source the user's rc — but the config file
keeps the wrapper correct for any launcher.)

### Degradation policy

- **Hard-fail on secret sync failure.** If the GitHub secret cannot sync, abort
  `create` — git inside the sandbox would be broken, a silent and confusing
  failure. Applies to all callers.
- **Warn + continue** for non-critical augmentation (e.g. an absent optional
  helper-mount source). Log to the wrapper log; print a stderr warning.

## File layout (stow-managed)

| Path | Role |
| --- | --- |
| `dot-config/mysbx/config` → `~/.config/mysbx/config` | Settings; env overrides |
| `dot-local/bin/mysbx` → `~/.local/bin/mysbx` | `#!/usr/bin/env zsh` executable: load config → source core lib → dispatch |
| `extras/agent-sandboxing/lib/mysbx-core.zsh` | **Single source of truth**: config load, real-sbx resolve + self-guard, secret sync, helper mounts, naming, preset registry, create/exec augmentation |
| `extras/agent-sandboxing/20-mysbx.zsh` | Interactive rc: sources core lib; defines thin `mysbx-cc/ruby-cc/omp` (all-in-one) + `mysbx-build/check/update/omp-build/omp-clean` |

The core lib is sourced by both the executable and the interactive file — no
logic duplication.

### Rename map (mechanical)

- Commands: `dsbx-*` → `mysbx-*`
- Internal helpers/vars: `_dsbx_*` / `_DSBX_*` → `_mysbx_*` / `_MYSBX_*`
- Files: `20-dsbx.zsh` → `20-mysbx.zsh`; new `lib/mysbx-core.zsh`
- State: `~/.local/state/dsbx` → `~/.local/state/mysbx`; `dsbx.log` → `mysbx.log`
- Config: new `~/.config/mysbx/config`
- Docs: `agent-sandboxing` skill (`.claude/skills/agent-sandboxing/SKILL.md`) and
  `CLAUDE.md` notes updated to `mysbx`
- `init.zsh` sources `20-mysbx.zsh`; `nono-*` untouched

## Naming

`exec` has no agent slot, so it cannot see the preset. Two name-supply paths:

- **Products (e.g. superset): explicit name both phases.** Setup
  `mysbx create cc . --name <N>`; tab `mysbx exec <N> -- claude …`. Most faithful
  to sbx grammar, no derivation magic. This is the recommended product
  integration.
- **Interactive funcs: cwd-derive when name omitted.** `_mysbx_name` convention
  (`mysbx-<preset>-<cwd>` + worktree/workspace suffixes). `mysbx-cc` computes the
  name from preset + cwd to reconnect/exec without the user typing it. Derivation
  lives only in the interactive helpers, not the executable.
- **Vanilla passthrough:** sbx default `<agent>-<workdir>` applies; we do nothing.

## Clone support

`--clone` is accepted on the augmented `create` path and forwarded to
`sbx create --clone`. Helper bind mounts (ADC, plugins, dotfiles, state) are
still attached as additional read-only workspaces; `--clone` only changes how the
*primary* repo is provided (in-container clone vs bind). Default is bind-mount.

## Superset integration (reference use case)

Superset provisions a sandbox at **workspace creation** (once per worktree), not
per tab. It exposes:

- A per-workspace **setup command** run once at creation (`.superset/config.json`
  `setup[]` or `.superset/setup.sh`; `setup-terminal.ts`,
  `workspaces.ts:1045`).
- Per-tab **agent commands** as configurable argv (`command` + `args[]` +
  `promptArgs[]` + `env`), assembled as `[command, …args, …promptArgs, prompt]`,
  single-quoted, and typed into a PTY whose cwd is the worktree
  (`agents.ts:114`, `terminal.ts:905`).

Mapping (with `N = superset-$SUPERSET_WORKSPACE_ID`):

```
workspace setup command :  mysbx create cc . --name N
tab agent command (argv) :  command="mysbx", args=["exec","N","--","claude"]
   superset runs        ->  mysbx exec N -- claude '<prompt>'
   mysbx rewrites       ->  sbx exec N -- claude '<prompt>'   (+ TTL secret resync)
```

Setup names the sandbox explicitly; tabs reference it by the same name. Clone is
off (the worktree is on-host and superset expects to see agent edits in it). The
detailed superset-side wiring is out of scope for this spec (it lives in the
superset repo); this section only validates that mysbx's surface — identical to
sbx grammar — supports the two-phase model with no special casing.

## Testing

**bats-core** (`brew install bats-core`). A stub `sbx` placed earlier on PATH
records its argv so tests assert the wrapper forwards/assembles correctly.

Coverage:

- Dispatch routing: `create`/`run` with a preset agent augments; with a real
  agent (`claude`) forwards vanilla; custom verbs handled locally; `exec`
  resyncs+forwards; unknown verb forwarded verbatim.
- Config load: with/without config file; env-var override precedence.
- Real-sbx resolution + self-reference guard.
- `--clone` reaches `sbx create --clone`.
- Preset assembly: `mysbx create omp …` expands agent omp → real agent + expected
  kits + name + template in the forwarded argv.
- Interactive name derivation: `mysbx-cc` at a cwd computes the same name a prior
  `mysbx create cc .` produced at that cwd (helper-level, not executable).
- Secret-sync hard-fail aborts `create`.

Manual: point superset's setup command / agent argv at `mysbx`; confirm a tab
execs into the workspace sandbox; confirm interactive `mysbx-omp` works; clone
round-trip via the `sandbox-<name>` git remote.

## Migration

None. Existing `dsbx` sandboxes and `~/.local/state/dsbx` are abandoned;
recreate via `mysbx-*` as needed. Old `dsbx-*` commands are removed once
`20-mysbx.zsh` replaces `20-dsbx.zsh`.

## Open implementation-time checks

- Exact `sbx create` flag/positional ordering for `--clone` combined with
  additional workspaces and `--kit`, and whether the preset agent must be
  rewritten before or interleaved with those flags.
- Confirm `sbx` has no agent named `cc`/`ruby-cc`/`omp` now or imminently (the
  no-collision assumption); pick a fallback disambiguation if it ever changes.

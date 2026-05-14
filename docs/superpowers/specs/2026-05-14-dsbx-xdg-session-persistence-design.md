# dsbx XDG Directory Structure + Session Persistence

**Date:** 2026-05-14
**Status:** Approved

## Summary

1. Reorganize all dsbx host-side files into XDG-compliant directories with a consolidated `dsbx/` prefix
2. Add per-sandbox persistent state directories so Claude sessions, plans, project memory, and transcripts survive sandbox recreations
3. Extend `_dsbx_helper_mounts()` to support RW entries for state dir mounting

## XDG Directory Layout

All dsbx files reorganized under XDG dirs. XDG vars are already exported in `dot-zshenv`.

### Cache (`$XDG_CACHE_HOME/dsbx/`)

Build artifacts and download caches. Safe to delete; rebuild recovers them.

```
$XDG_CACHE_HOME/dsbx/                  # ~/.cache/dsbx/
└── omp-fork/                           # was ~/.cache/dsbx-omp-fork
```

Docker named volumes (`dsbx-omp-fork-buncache`, `dsbx-omp-fork-cargocache`) are unchanged — they're Docker-managed, not filesystem paths.

### State (`$XDG_STATE_HOME/dsbx/`)

Runtime state: logs, sync markers, per-sandbox persistent data. Not config, not cache — state that accumulates during use.

```
$XDG_STATE_HOME/dsbx/                  # ~/.local/state/dsbx/
├── dsbx.log                            # was ~/.cache/dsbx-auth/dsbx.log
├── markers/                            # was flat files in ~/.cache/dsbx-auth/
│   ├── <sandbox-name>.gh-secret
│   └── ...
└── sandboxes/                          # NEW: per-sandbox persistent state
    └── <sandbox-name>/
        ├── sessions/                   # Claude conversation metadata (/resume)
        ├── plans/                      # Active implementation plans
        ├── projects/                   # Session transcripts + project memory
        └── history.jsonl               # Conversation index
```

### Config (`$XDG_CONFIG_HOME/dsbx/`)

Reserved for future dsbx-specific configuration. Not created by this change.

## Variable Renames in `20-dsbx.zsh`

| Old | New |
|---|---|
| `_DSBX_AUTH_DIR="$HOME/.cache/dsbx-auth"` | `_DSBX_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dsbx"` |
| `_DSBX_LOG="$HOME/.cache/dsbx-auth/dsbx.log"` | `_DSBX_LOG="$_DSBX_STATE_DIR/dsbx.log"` |
| `_DSBX_OMP_FORK_CACHE_DIR="$HOME/.cache/dsbx-omp-fork"` | `_DSBX_OMP_FORK_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dsbx/omp-fork"` |

All marker functions updated to use `$_DSBX_STATE_DIR/markers/` subdirectory.

## Sandbox State Persistence

### Problem

When a sandbox is recreated (`--recreate` or mount staleness auto-recreate), all sandbox filesystem state is destroyed. Claude sessions, project memory, plans, and conversation history are lost. Users must start fresh each time.

### Solution

Each sandbox gets a host-side state directory under `$_DSBX_STATE_DIR/sandboxes/<sandbox-name>/`. This directory:

1. Is created by `_dsbx_run` before `sbx create`
2. Is bind-mounted RW into the sandbox as a workspace
3. Kit `install.sh` symlinks its subdirs into `~/.claude/` inside the sandbox
4. Survives `--recreate` — only the container is destroyed, not the host state dir

### What persists

| Host path (relative to sandbox state dir) | Sandbox path | Purpose |
|---|---|---|
| `sessions/` | `~/.claude/sessions/` | Conversation metadata, enables `/resume` |
| `plans/` | `~/.claude/plans/` | Active implementation plans |
| `projects/` | `~/.claude/projects/` | Session transcripts (`.jsonl`) + project memory (`memory/` subdirs) |
| `history.jsonl` | `~/.claude/history.jsonl` | Conversation index, powers `/resume` search |

### What does NOT persist (regenerated each sandbox lifecycle)

- `file-history/` — pre-edit snapshots, session-scoped
- `backups/` — ephemeral config backups
- `session-env/` — per-session environment
- `shell-snapshots/` — shell state captures
- `stats-cache.json` — usage stats
- `powerline/` — usage tracking

## Changes to `_dsbx_helper_mounts()`

Currently all helper mount candidates get `:ro` appended. Extended to support both RO and RW entries by embedding the access mode in the candidate list.

```zsh
_dsbx_helper_mounts() {
  local -a mounts=()
  local cwd; cwd="$(pwd -P)"
  local sandbox_state="$1"
  local -a candidates=(
    "$_DSBX_HELPER_ADC_DIR:ro"
    "$_DSBX_HELPER_PLUGINS_DIR:ro"
    "$_DSBX_HELPER_DOTFILES_DIR:ro"
    "$_DSBX_OMP_FORK_CACHE_DIR:ro"
    "$sandbox_state"
  )
  for entry in "${candidates[@]}"; do
    local d="${entry%%:*}"
    [ -d "$d" ] || continue
    [[ "$cwd" == "$d"* ]] && continue
    mounts+=("$entry")
  done
  printf '%s\n' "${mounts[@]}"
}
```

Entries without `:ro` suffix are mounted RW (sbx default). The state dir is the only RW entry.

## Changes to `_dsbx_run()`

### State dir creation

Before the `sbx create` call:

```zsh
local sandbox_state_dir="$_DSBX_STATE_DIR/sandboxes/$name"
mkdir -p "$sandbox_state_dir"/{sessions,plans,projects}
[ -f "$sandbox_state_dir/history.jsonl" ] || touch "$sandbox_state_dir/history.jsonl"
```

### Helper mounts call

Pass sandbox state dir as first argument:

```zsh
helper_mounts=(${(f)"$(_dsbx_helper_mounts "$sandbox_state_dir")"})
```

### Recreate behavior

`--recreate` clears sync markers but does **not** delete the sandbox state dir:

```zsh
if (( recreate )); then
  sbx rm -f "$name" >> "$_DSBX_LOG" 2>&1 || true
  _dsbx_purge_orphans "$name"
  rm -f "$_DSBX_STATE_DIR/markers/${name}.gh-secret"
  # NOTE: sandbox_state_dir is intentionally preserved
fi
```

## Changes to `install.sh` (Personal Kit)

Add step 6 after existing steps. Discovers the sandbox state dir from bind mounts using the same host-home discovery pattern:

```bash
# 6. Claude session state persistence
# Discover sandbox state dir from bind mounts
DSBX_STATE=""
if [ -n "$HOST_HOME" ]; then
  for _d in "$HOST_HOME/.local/state/dsbx/sandboxes"/*/; do
    [ -d "${_d}sessions" ] && { DSBX_STATE="${_d%/}"; break; }
  done
fi

if [ -n "$DSBX_STATE" ]; then
  mkdir -p "$HOME/.claude"
  for subdir in sessions plans projects; do
    [ -d "$DSBX_STATE/$subdir" ] && ln -sfn "$DSBX_STATE/$subdir" "$HOME/.claude/$subdir"
  done
  [ -f "$DSBX_STATE/history.jsonl" ] && \
    ln -sf "$DSBX_STATE/history.jsonl" "$HOME/.claude/history.jsonl"
fi
```

Discovery relies on `HOST_HOME` already being set (step 0 of install.sh). Scans `$HOST_HOME/.local/state/dsbx/sandboxes/*/` for a dir containing `sessions/`. Since only one sandbox state dir is mounted per container, first match wins.

## Marker Path Changes

```zsh
_dsbx_secret_marker() {
  local sandbox_name="$1"
  echo "$_DSBX_STATE_DIR/markers/${sandbox_name}.gh-secret"
}
```

`mkdir -p "$_DSBX_STATE_DIR/markers"` added to `_dsbx_sync_github_secret` alongside existing `mkdir -p`.

## `_dsbx_helper_mounts_stale` Impact

Adding the state dir mount means all existing sandboxes will auto-detect as stale (missing the new mount) and auto-recreate on next run. This is correct — they need recreate to pick up new mounts. No code change needed to the stale-check function itself.

## Migration

### One-time cleanup

```bash
# Move omp fork cache to new location
mkdir -p ~/.cache/dsbx
[ -d ~/.cache/dsbx-omp-fork ] && mv ~/.cache/dsbx-omp-fork ~/.cache/dsbx/omp-fork

# Remove old auth dir (markers will be recreated on next sync)
rm -rf ~/.cache/dsbx-auth

# Recreate sandboxes to pick up new mounts
# (auto-happens on next dsbx-* invocation via stale-mount detection)
```

### No backward compat shims

Old paths are removed entirely. Existing sandboxes auto-recreate due to stale mount detection. Markers are cheap to regenerate (next `op read` cycle).

## Edge Cases

| Case | Behavior |
|---|---|
| First run (no state dir exists) | `_dsbx_run` creates it with empty subdirs. Sandbox starts fresh. |
| `--recreate` with existing state | Container destroyed, state dir preserved. New sandbox gets state via symlinks. |
| Auto-recreate (stale mounts) | Same as `--recreate` — state survives. |
| `XDG_STATE_HOME` not set | Falls back to `$HOME/.local/state` per XDG spec. |
| `XDG_CACHE_HOME` not set | Falls back to `$HOME/.cache` per XDG spec. |
| State dir manually deleted | Recreated on next `_dsbx_run`. Sandbox starts fresh. |
| Multiple sandboxes for same CWD | Each has its own state dir (sandbox names differ by prefix). |

## Implementation Risks (validate during implementation)

1. **`_dsbx_helper_mounts_stale` with mixed RO/RW entries** — The stale check does `grep -qxF` matching mount strings against `sbx ls --json` workspace output. Verify that `sbx ls` reports workspaces with `:ro` suffixes for RO mounts and without suffixes for RW mounts, matching our candidate format. If sbx normalizes the output differently, the stale check comparison needs adjustment.

2. **State dir as workspace mount** — Verify that sbx supports non-CWD directories as workspace mounts without the `:ro` suffix (RW mode). All current helper mounts use `:ro`; the state dir is the first RW helper mount.

## Scope

- `20-dsbx.zsh` — variable renames, `_dsbx_helper_mounts` extension, `_dsbx_run` state dir creation
- `kits/personal/files/home/install.sh` — add step 6 for state dir symlinks
- No changes to: `00-shared.zsh`, `10-nono.zsh`, `init.zsh`, Dockerfiles, kit specs, docker-compose.yml
- No changes to OMP session persistence (deferred)

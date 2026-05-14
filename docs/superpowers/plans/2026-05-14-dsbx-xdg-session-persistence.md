# dsbx XDG Directory Structure + Session Persistence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize all dsbx host-side files into XDG-compliant directories and add per-sandbox persistent state so Claude sessions survive sandbox recreations.

**Architecture:** Replace hardcoded `~/.cache/dsbx-*` paths with `$XDG_CACHE_HOME/dsbx/` and `$XDG_STATE_HOME/dsbx/`. Add per-sandbox state directories under `$XDG_STATE_HOME/dsbx/sandboxes/<name>/` that are bind-mounted RW into sandboxes. Kit `install.sh` symlinks persisted subdirs into `~/.claude/` inside the container.

**Tech Stack:** zsh (20-dsbx.zsh), bash (install.sh), Docker sbx CLI

---

### Task 1: Rename top-level variables to XDG paths

**Files:**
- Modify: `extras/agent-sandboxing/20-dsbx.zsh:3-6` (variable declarations)
- Modify: `extras/agent-sandboxing/20-dsbx.zsh:112` (`_DSBX_OMP_FORK_CACHE_DIR`)

- [ ] **Step 1: Replace `_DSBX_AUTH_DIR` and `_DSBX_LOG` with XDG state dir**

In `extras/agent-sandboxing/20-dsbx.zsh`, replace lines 3-5:

```zsh
# Old:
_DSBX_AUTH_DIR="$HOME/.cache/dsbx-auth"
_DSBX_LOG="$HOME/.cache/dsbx-auth/dsbx.log"

# New:
_DSBX_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dsbx"
_DSBX_LOG="$_DSBX_STATE_DIR/dsbx.log"
```

- [ ] **Step 2: Replace `_DSBX_OMP_FORK_CACHE_DIR` with XDG cache dir**

In `extras/agent-sandboxing/20-dsbx.zsh`, replace line 112:

```zsh
# Old:
_DSBX_OMP_FORK_CACHE_DIR="$HOME/.cache/dsbx-omp-fork"

# New:
_DSBX_OMP_FORK_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dsbx/omp-fork"
```

- [ ] **Step 3: Verify no remaining references to old variable names**

Run:

```bash
rg '_DSBX_AUTH_DIR' extras/agent-sandboxing/20-dsbx.zsh
```

Expected: No matches. If any remain, they're updated in subsequent tasks (marker functions).

- [ ] **Step 4: Commit**

```bash
git add extras/agent-sandboxing/20-dsbx.zsh
git commit -m "refactor(dsbx): rename top-level variables to XDG paths

Replace _DSBX_AUTH_DIR with _DSBX_STATE_DIR under \$XDG_STATE_HOME/dsbx/.
Move _DSBX_OMP_FORK_CACHE_DIR under \$XDG_CACHE_HOME/dsbx/omp-fork."
```

---

### Task 2: Update marker functions to use `markers/` subdirectory

**Files:**
- Modify: `extras/agent-sandboxing/20-dsbx.zsh:42-44` (`_dsbx_secret_marker`)
- Modify: `extras/agent-sandboxing/20-dsbx.zsh:58-84` (`_dsbx_sync_github_secret`)

- [ ] **Step 1: Update `_dsbx_secret_marker` to use `markers/` subdir**

Replace the function at line 42-45:

```zsh
# Old:
_dsbx_secret_marker() {
  local sandbox_name="$1"
  echo "$_DSBX_AUTH_DIR/${sandbox_name}.gh-secret"
}

# New:
_dsbx_secret_marker() {
  local sandbox_name="$1"
  echo "$_DSBX_STATE_DIR/markers/${sandbox_name}.gh-secret"
}
```

- [ ] **Step 2: Update `mkdir -p` in `_dsbx_sync_github_secret`**

In the `_dsbx_sync_github_secret` function, replace the `mkdir -p` call (line 64):

```zsh
# Old:
  mkdir -p "$_DSBX_AUTH_DIR"

# New:
  mkdir -p "$_DSBX_STATE_DIR/markers"
```

- [ ] **Step 3: Verify all `_DSBX_AUTH_DIR` references are gone**

Run:

```bash
rg '_DSBX_AUTH_DIR' extras/agent-sandboxing/20-dsbx.zsh
```

Expected: Zero matches. Every reference should now use `_DSBX_STATE_DIR` or `_DSBX_STATE_DIR/markers`.

- [ ] **Step 4: Commit**

```bash
git add extras/agent-sandboxing/20-dsbx.zsh
git commit -m "refactor(dsbx): move sync markers to \$XDG_STATE_HOME/dsbx/markers/"
```

---

### Task 3: Extend `_dsbx_helper_mounts()` to accept sandbox state dir

**Files:**
- Modify: `extras/agent-sandboxing/20-dsbx.zsh:101-134` (`_dsbx_helper_mounts` function + comment block)

- [ ] **Step 1: Rewrite `_dsbx_helper_mounts` to accept state dir and embed access modes**

Replace the function and its preceding comment (lines 101-134):

```zsh
# Helper bind mounts. Workspaces appended to `sbx create` but excluded from
# the sandbox name (so they don't bloat sandbox identity). Candidates carry
# their own access-mode suffix: `:ro` for read-only, bare path for read-write.
# Entries whose host path is missing are silently skipped.
_dsbx_helper_mounts() {
  local sandbox_state="$1"
  local -a mounts=()
  local cwd; cwd="$(pwd -P)"
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
    # Skip if this mount is a parent or equal to CWD (already mounted as workspace)
    [[ "$cwd" == "$d"* ]] && continue
    mounts+=("$entry")
  done
  printf '%s\n' "${mounts[@]}"
}
```

Key changes from the old version:
- Takes `$1` as sandbox state dir path (RW, no `:ro` suffix)
- Candidates now embed their access mode (`:ro` or bare)
- Loop variable renamed from `d` to `entry`; path extracted via `${entry%%:*}`
- Entries are emitted as-is (including or excluding `:ro`)

- [ ] **Step 2: Commit**

```bash
git add extras/agent-sandboxing/20-dsbx.zsh
git commit -m "feat(dsbx): extend _dsbx_helper_mounts to support RW entries

Accept sandbox state dir as \$1, emitted without :ro suffix.
Existing mounts now carry explicit :ro in the candidates list."
```

---

### Task 4: Add sandbox state dir creation and wiring in `_dsbx_run`

**Files:**
- Modify: `extras/agent-sandboxing/20-dsbx.zsh:277-346` (`_dsbx_run` function)

This is the core task. Three changes inside `_dsbx_run`:

1. Create per-sandbox state dir on host
2. Pass state dir to `_dsbx_helper_mounts`
3. Update `--recreate` to preserve state dir but clear markers at new path

- [ ] **Step 1: Add state dir creation after `name` is computed**

After line 306 (`name="$(_dsbx_name "$prefix" "${extra_ws[@]}")`), insert:

```zsh
  local sandbox_state_dir="$_DSBX_STATE_DIR/sandboxes/$name"
  mkdir -p "$sandbox_state_dir"/{sessions,plans,projects}
  [ -f "$sandbox_state_dir/history.jsonl" ] || touch "$sandbox_state_dir/history.jsonl"
```

- [ ] **Step 2: Update `_dsbx_helper_mounts` call to pass state dir**

Replace line 308:

```zsh
# Old:
  helper_mounts=(${(f)"$(_dsbx_helper_mounts)"})

# New:
  helper_mounts=(${(f)"$(_dsbx_helper_mounts "$sandbox_state_dir")"})
```

- [ ] **Step 3: Update `--recreate` block to use new marker path**

Replace the recreate block (lines 315-320):

```zsh
# Old:
  if (( recreate )); then
    echo "$(date -Iseconds) Recreating $name" >> "$_DSBX_LOG"
    sbx rm -f "$name" >> "$_DSBX_LOG" 2>&1 || true
    _dsbx_purge_orphans "$name"
    rm -f "$(_dsbx_secret_marker "$name")"
  fi

# New:
  if (( recreate )); then
    echo "$(date -Iseconds) Recreating $name" >> "$_DSBX_LOG"
    sbx rm -f "$name" >> "$_DSBX_LOG" 2>&1 || true
    _dsbx_purge_orphans "$name"
    rm -f "$_DSBX_STATE_DIR/markers/${name}.gh-secret"
  fi
```

Note: `_dsbx_secret_marker` already returns the new path (updated in Task 2), so either `rm -f "$(_dsbx_secret_marker "$name")"` or the literal path works. Using the literal here for clarity and to avoid a subshell. Either form is correct.

- [ ] **Step 4: Verify the full `_dsbx_run` function reads correctly**

Run:

```bash
sed -n '/^_dsbx_run()/,/^}/p' extras/agent-sandboxing/20-dsbx.zsh
```

Verify:
- `sandbox_state_dir` is declared and `mkdir -p` runs before the stale check
- `_dsbx_helper_mounts` receives `"$sandbox_state_dir"` as `$1`
- The recreate block does NOT `rm -rf "$sandbox_state_dir"` — state must survive

- [ ] **Step 5: Commit**

```bash
git add extras/agent-sandboxing/20-dsbx.zsh
git commit -m "feat(dsbx): create per-sandbox state dirs and mount RW

Each sandbox gets a host-side state directory at
\$XDG_STATE_HOME/dsbx/sandboxes/<name>/ with sessions/, plans/,
projects/, and history.jsonl. Mounted RW via _dsbx_helper_mounts.
Preserved across --recreate."
```

---

### Task 5: Add state dir symlinks in kit `install.sh`

**Files:**
- Modify: `extras/agent-sandboxing/kits/personal/files/home/install.sh:70-77` (append after step 5)

- [ ] **Step 1: Add step 6 for Claude session state persistence**

Append after step 5 (SSH known_hosts merge), before the final line / end of file:

```bash
# 6. Claude session state persistence
# Discover sandbox state dir from bind mounts — the host-side
# $XDG_STATE_HOME/dsbx/sandboxes/<name>/ is mounted RW at its host path.
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

Discovery logic:
- Uses `HOST_HOME` already set in step 0 of install.sh
- Scans `$HOST_HOME/.local/state/dsbx/sandboxes/*/` for a dir containing `sessions/`
- First match wins (only one sandbox state dir mounted per container)
- Symlinks `sessions/`, `plans/`, `projects/` dirs and `history.jsonl` file into `~/.claude/`
- Conditional on each path existing — graceful no-op if state dir not found

- [ ] **Step 2: Commit**

```bash
git add extras/agent-sandboxing/kits/personal/files/home/install.sh
git commit -m "feat(dsbx): symlink persisted state dirs into sandbox ~/.claude/

Kit install.sh discovers the host-mounted state dir and symlinks
sessions/, plans/, projects/, and history.jsonl into ~/.claude/ so
Claude sessions survive sandbox recreations."
```

---

### Task 6: Smoke test and cleanup verification

**Files:**
- No file modifications — runtime validation only

- [ ] **Step 1: Verify variable resolution**

Source the modified file and check variable values:

```bash
source extras/agent-sandboxing/init.zsh && \
  echo "_DSBX_STATE_DIR=$_DSBX_STATE_DIR" && \
  echo "_DSBX_LOG=$_DSBX_LOG" && \
  echo "_DSBX_OMP_FORK_CACHE_DIR=$_DSBX_OMP_FORK_CACHE_DIR"
```

Expected output:

```
_DSBX_STATE_DIR=/Users/trevor.smith/.local/state/dsbx
_DSBX_LOG=/Users/trevor.smith/.local/state/dsbx/dsbx.log
_DSBX_OMP_FORK_CACHE_DIR=/Users/trevor.smith/.cache/dsbx/omp-fork
```

- [ ] **Step 2: Verify no remaining references to old paths**

```bash
rg '_DSBX_AUTH_DIR|\.cache/dsbx-auth|\.cache/dsbx-omp-fork' extras/agent-sandboxing/
```

Expected: Zero matches. All old paths replaced.

- [ ] **Step 3: Verify helper mounts output includes state dir**

```bash
source extras/agent-sandboxing/init.zsh && \
  mkdir -p /tmp/test-state/sessions && \
  _dsbx_helper_mounts /tmp/test-state && \
  rm -rf /tmp/test-state
```

Expected: output includes `/tmp/test-state` (without `:ro`) alongside other entries with `:ro`.

- [ ] **Step 4: Document migration steps for the user**

Print these one-time migration commands (do NOT run them automatically — user should run manually):

```bash
# One-time migration — run manually after sourcing new shell config:
# 1. Move omp fork cache
mkdir -p ~/.cache/dsbx
[ -d ~/.cache/dsbx-omp-fork ] && mv ~/.cache/dsbx-omp-fork ~/.cache/dsbx/omp-fork
# 2. Remove old auth dir
rm -rf ~/.cache/dsbx-auth
# 3. Existing sandboxes will auto-recreate on next dsbx-* invocation
```

- [ ] **Step 5: Commit spec update (if any edge cases surfaced during testing)**

Only if adjustments were made during smoke testing. Otherwise skip.

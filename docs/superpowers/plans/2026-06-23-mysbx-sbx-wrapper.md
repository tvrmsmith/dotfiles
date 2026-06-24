# mysbx — sbx Wrapper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `dsbx-*` zsh functions with a standalone `mysbx` executable that is a faithful superset of Docker `sbx` — augmenting `create`/`run` only when the agent positional names a preset (`cc`/`ruby-cc`/`omp`) — plus rebrand everything `dsbx` → `mysbx`.

**Architecture:** A single core library (`extras/agent-sandboxing/lib/mysbx-core.zsh`) holds all logic. A thin executable (`dot-local/bin/mysbx` → `~/.local/bin/mysbx`) sources it and dispatches on the verb. A thin interactive file (`extras/agent-sandboxing/20-mysbx.zsh`) sources it and defines the interactive `mysbx-*` convenience functions (all-in-one create-if-needed launch). The core lib uses `$REAL_SBX` (resolved once, with a self-reference guard) for every real-sbx call, never bare `sbx`.

**Tech Stack:** zsh, Docker `sbx`, 1Password CLI (`op`), bats-core (tests), GNU Stow.

## Global Constraints

- Preset is the agent positional of `create`/`run`, never a flag. Presets: `cc`, `ruby-cc`, `omp`. Dispatch keys on the verb (`$1`).
- Augmentation is opt-in: only when `create`/`run`'s agent positional is a known preset. Any real agent (`claude`, …) forwards vanilla.
- Preset → real agent: `cc`→`claude`, `ruby-cc`→`claude`, `omp`→`omp`.
- Core lib must call `$REAL_SBX`, never bare `sbx`. `REAL_SBX` resolves from config, else `command -v sbx`; abort if it resolves back to the wrapper.
- Secrets never enter argv: pipe via stdin (`printf '%s' "$token" | $REAL_SBX secret set …`).
- Hard-fail `create` if GitHub secret sync fails; warn+continue for non-critical augmentation (missing optional mount source).
- 1Password reads are directory-aware: under `$DEV_PERSONAL/` → personal account + per-sandbox secret scope; else work account + global (`-g`) scope. Atlassian secret synced only off-personal.
- Full rebrand `dsbx`→`mysbx` (commands, `_dsbx_*`/`_DSBX_*`→`_mysbx_*`/`_MYSBX_*`, files, state dir `~/.local/state/mysbx`, log `mysbx.log`, config `~/.config/mysbx/config`). No migration of old `dsbx` sandboxes/state. `nono-*` untouched.
- Files/dirs prefixed `dot-` are stowed into `$HOME` with `.` prefix via `stow --dotfiles`.

---

## File Structure

| Path | Responsibility |
| --- | --- |
| `dot-config/mysbx/config` | Settings with env-override defaults (`DEV_PERSONAL`, token paths, `JIRA_USERNAME`, `REAL_SBX`, TTL). |
| `dot-local/bin/mysbx` | Executable: resolve+source core lib, load config, dispatch on verb. |
| `extras/agent-sandboxing/lib/mysbx-core.zsh` | Single source of truth: config load, real-sbx resolve+guard, timing/log, secret sync, helper mounts, naming, preset registry, purge-orphans, augmented create/run, exec resync, custom-verb impls, interactive launch. |
| `extras/agent-sandboxing/20-mysbx.zsh` | Interactive rc: source core; define `mysbx-cc/ruby-cc/omp` (all-in-one) + thin `mysbx-build/check/update/omp-build/omp-clean`. |
| `extras/agent-sandboxing/tests/` | bats tests + stub `sbx`/`op`/`docker` on PATH. |
| `extras/agent-sandboxing/20-dsbx.zsh` | **Deleted** in Task 9. |

The current logic lives in `extras/agent-sandboxing/20-dsbx.zsh` (476 lines). Most core functions are ported by applying the rename map (`dsbx`→`mysbx`, `sbx`→`$REAL_SBX`); each task cites the exact source lines.

---

## Task 1: Scaffolding — core lib, config, executable, passthrough

**Files:**
- Create: `extras/agent-sandboxing/lib/mysbx-core.zsh`
- Create: `dot-config/mysbx/config`
- Create: `dot-local/bin/mysbx`
- Create: `extras/agent-sandboxing/tests/helpers/stub-bin/sbx`
- Create: `extras/agent-sandboxing/tests/helpers/setup.bash`
- Test: `extras/agent-sandboxing/tests/dispatch.bats`

**Interfaces:**
- Produces: core lib sets globals `REAL_SBX`, `_AGENT_SBX_ROOT`, `_MYSBX_STATE_DIR`, `_MYSBX_LOG`, `_MYSBX_SECRET_TTL`, `DEV_PERSONAL`, `GIT_TOKEN`, `GIT_TOKEN_PERSONAL`, `JIRA_USERNAME` after sourcing. Functions: `_mysbx_load_config`, `_mysbx_resolve_real_sbx`, `mysbx_dispatch "$@"`.
- The executable invokes `mysbx_dispatch "$@"`.
- Tests set `MYSBX_CORE` (path to core lib) and `REAL_SBX` (stub) before invoking the executable.

- [ ] **Step 1: Write the stub `sbx`**

`extras/agent-sandboxing/tests/helpers/stub-bin/sbx`:
```bash
#!/usr/bin/env bash
# Records argv (one arg per line) to $STUB_SBX_LOG, then exits $STUB_SBX_RC (default 0).
# For `ls`, prints $STUB_SBX_LS_OUTPUT so existence checks can be driven.
printf '%s\n' "$@" >> "${STUB_SBX_LOG:?STUB_SBX_LOG unset}"
if [ "$1" = ls ]; then
  printf '%s' "${STUB_SBX_LS_OUTPUT:-}"
fi
exit "${STUB_SBX_RC:-0}"
```
Make executable: `chmod +x extras/agent-sandboxing/tests/helpers/stub-bin/sbx`

- [ ] **Step 2: Write the bats setup helper**

`extras/agent-sandboxing/tests/helpers/setup.bash`:
```bash
# Shared bats setup. Sourced by each .bats file.
_mysbx_test_setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SBX_ROOT="$REPO_ROOT/extras/agent-sandboxing"
  export MYSBX_CORE="$SBX_ROOT/lib/mysbx-core.zsh"
  export MYSBX="$REPO_ROOT/dot-local/bin/mysbx"

  TMP="$(mktemp -d)"
  export STUB_SBX_LOG="$TMP/sbx.argv"
  : > "$STUB_SBX_LOG"
  export REAL_SBX="$SBX_ROOT/tests/helpers/stub-bin/sbx"

  # Isolated state/config so tests never touch real dirs.
  export XDG_STATE_HOME="$TMP/state"
  export XDG_CACHE_HOME="$TMP/cache"
  export HOME_STUB="$TMP/home"
  mkdir -p "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$HOME_STUB"

  # Stubs (op/docker) earlier on PATH; real zsh still found.
  export PATH="$SBX_ROOT/tests/helpers/stub-bin:$PATH"

  export DEV_PERSONAL="$TMP/dev/personal"
  mkdir -p "$DEV_PERSONAL"
}
_mysbx_test_teardown() { rm -rf "$TMP"; }
# Read recorded sbx argv as a newline string.
sbx_argv() { cat "$STUB_SBX_LOG"; }
```

- [ ] **Step 3: Write the core lib skeleton (config + real-sbx + dispatch passthrough)**

`extras/agent-sandboxing/lib/mysbx-core.zsh`:
```zsh
# mysbx core — single source of truth. Sourced by the mysbx executable and by
# the interactive 20-mysbx.zsh. Idempotent.
[[ -n "${_MYSBX_CORE_LOADED:-}" ]] && return 0
_MYSBX_CORE_LOADED=1

# Resolve roots from this file's own location (works sourced or via the symlinked
# executable, since :A resolves symlinks).
_MYSBX_LIB_DIR="${0:A:h}"
_AGENT_SBX_ROOT="${_MYSBX_LIB_DIR:h}"

# Shared worktree detection (_detect_git_worktree).
source "$_AGENT_SBX_ROOT/00-shared.zsh"

zmodload zsh/datetime 2>/dev/null

# --- Config -----------------------------------------------------------------
# Load ~/.config/mysbx/config if present, then apply defaults for anything still
# unset. Environment always wins (config uses `: ${VAR:=...}`).
_mysbx_load_config() {
  local cfg="${XDG_CONFIG_HOME:-$HOME/.config}/mysbx/config"
  [[ -r "$cfg" ]] && source "$cfg"
  : ${DEV_PERSONAL:="$HOME/dev/personal"}
  : ${GIT_TOKEN:="op://Employee/GitHub Personal Access Token/token"}
  : ${GIT_TOKEN_PERSONAL:="op://Private/GitHub Personal Access Token/token"}
  : ${JIRA_USERNAME:="trevor.smith@wellsky.com"}
  : ${MYSBX_SECRET_TTL:=3600}
  _MYSBX_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/mysbx"
  _MYSBX_LOG="$_MYSBX_STATE_DIR/mysbx.log"
  _MYSBX_SECRET_TTL="$MYSBX_SECRET_TTL"
  mkdir -p "$_MYSBX_STATE_DIR"
}

# --- Real sbx resolution ----------------------------------------------------
# Echo the absolute path to the genuine sbx binary. Honors $REAL_SBX from config;
# else `command -v sbx`. Aborts if it resolves back to this wrapper.
_mysbx_resolve_real_sbx() {
  local cand="${REAL_SBX:-}"
  [[ -z "$cand" ]] && cand="$(command -v sbx 2>/dev/null)"
  if [[ -z "$cand" ]]; then
    echo "[mysbx] cannot find real sbx (set REAL_SBX in ~/.config/mysbx/config)" >&2
    return 1
  fi
  if [[ "${cand:t}" == "mysbx" ]]; then
    echo "[mysbx] REAL_SBX resolves to the wrapper itself ($cand)" >&2
    return 1
  fi
  REAL_SBX="$cand"
}

# --- Dispatch ---------------------------------------------------------------
# Verb-first, identical to sbx grammar. Augmentation handled in later tasks.
mysbx_dispatch() {
  _mysbx_load_config
  _mysbx_resolve_real_sbx || return 1
  local verb="${1:-}"
  case "$verb" in
    "" ) exec "$REAL_SBX" ;;
    * )  exec "$REAL_SBX" "$@" ;;   # passthrough (overridden for known verbs later)
  esac
}
```

- [ ] **Step 4: Write the config file**

`dot-config/mysbx/config`:
```zsh
# ~/.config/mysbx/config — sourced by mysbx. Environment variables take
# precedence (each line only sets the value if currently unset).
: ${DEV_PERSONAL:="$HOME/dev/personal"}
: ${GIT_TOKEN:="op://Employee/GitHub Personal Access Token/token"}
: ${GIT_TOKEN_PERSONAL:="op://Private/GitHub Personal Access Token/token"}
: ${JIRA_USERNAME:="trevor.smith@wellsky.com"}
: ${MYSBX_SECRET_TTL:=3600}
# Leave REAL_SBX unset to auto-resolve via `command -v sbx`.
# : ${REAL_SBX:="/opt/homebrew/bin/sbx"}
```

- [ ] **Step 5: Write the executable**

`dot-local/bin/mysbx`:
```zsh
#!/usr/bin/env zsh
# mysbx — faithful sbx superset with smart-agent presets. See
# docs/superpowers/specs/2026-06-23-mysbx-sbx-wrapper-design.md
emulate -L zsh
setopt no_unset pipe_fail

# Locate the core lib. MYSBX_CORE overrides (tests); else derive from this
# script's real path: dot-local/bin/mysbx -> repo root -> extras/...
local core="${MYSBX_CORE:-}"
if [[ -z "$core" ]]; then
  local repo_root="${0:A:h:h:h}"
  core="$repo_root/extras/agent-sandboxing/lib/mysbx-core.zsh"
fi
if [[ ! -r "$core" ]]; then
  echo "[mysbx] core lib not found: $core" >&2
  exit 1
fi
source "$core"
mysbx_dispatch "$@"
```
Make executable: `chmod +x dot-local/bin/mysbx`

- [ ] **Step 6: Write dispatch tests**

`extras/agent-sandboxing/tests/dispatch.bats`:
```bash
load helpers/setup
setup() { _mysbx_test_setup; }
teardown() { _mysbx_test_teardown; }

@test "unknown verb forwards verbatim to real sbx" {
  run zsh "$MYSBX" ls --json
  [ "$status" -eq 0 ]
  [ "$(sbx_argv)" = "$(printf 'ls\n--json')" ]
}

@test "no args forwards bare to real sbx" {
  run zsh "$MYSBX"
  [ "$status" -eq 0 ]
  [ "$(sbx_argv)" = "" ]
}

@test "self-reference guard aborts" {
  cp "$MYSBX" "$TMP/mysbx"; chmod +x "$TMP/mysbx"
  REAL_SBX="$TMP/mysbx" run zsh "$MYSBX" ls
  [ "$status" -ne 0 ]
  [[ "$output" == *"resolves to the wrapper itself"* ]]
}

@test "env overrides config default for DEV_PERSONAL" {
  run zsh -c "source '$MYSBX_CORE'; _mysbx_load_config; print \$DEV_PERSONAL"
  [ "$status" -eq 0 ]
  [ "$output" = "$DEV_PERSONAL" ]
}
```

- [ ] **Step 7: Run tests — expect pass**

Run: `bats extras/agent-sandboxing/tests/dispatch.bats`
Expected: 4 passing.

- [ ] **Step 8: Commit**

```bash
git add extras/agent-sandboxing/lib/mysbx-core.zsh dot-config/mysbx/config \
  dot-local/bin/mysbx extras/agent-sandboxing/tests
git commit -m "feat(mysbx): scaffold core lib, config, executable, passthrough"
```

---

## Task 2: Preset registry + naming

**Files:**
- Modify: `extras/agent-sandboxing/lib/mysbx-core.zsh` (add registry + naming)
- Test: `extras/agent-sandboxing/tests/registry.bats`

**Interfaces:**
- Consumes: `_AGENT_SBX_ROOT`, `_detect_git_worktree`/`_GIT_WORKTREE_SOURCE_REPO` (from `00-shared.zsh`).
- Produces:
  - `_mysbx_is_preset <name>` → 0 if name ∈ {cc,ruby-cc,omp}.
  - `_mysbx_preset_agent <preset>` → echoes real agent (`claude`/`omp`).
  - `_mysbx_preset_template <preset>` → echoes template or empty.
  - `_mysbx_preset_kits <preset>` → echoes kit dir paths, one per line (atlassian appended only off-personal).
  - `_mysbx_name <prefix> [extra_ws...]` → echoes sandbox name.
  - `_mysbx_is_personal` → 0 if cwd under `$DEV_PERSONAL/`.

- [ ] **Step 1: Write the failing test**

`extras/agent-sandboxing/tests/registry.bats`:
```bash
load helpers/setup
setup() { _mysbx_test_setup; }
teardown() { _mysbx_test_teardown; }

run_core() { zsh -c "source '$MYSBX_CORE'; _mysbx_load_config; $1"; }

@test "is_preset recognizes presets, rejects real agents" {
  run run_core '_mysbx_is_preset cc && _mysbx_is_preset ruby-cc && _mysbx_is_preset omp && echo ok'
  [ "$output" = ok ]
  run run_core '_mysbx_is_preset claude'
  [ "$status" -ne 0 ]
}

@test "preset_agent maps presets to real agents" {
  [ "$(run_core '_mysbx_preset_agent cc')" = claude ]
  [ "$(run_core '_mysbx_preset_agent ruby-cc')" = claude ]
  [ "$(run_core '_mysbx_preset_agent omp')" = omp ]
}

@test "preset_template only set for ruby-cc" {
  [ "$(run_core '_mysbx_preset_template cc')" = "" ]
  [ "$(run_core '_mysbx_preset_template ruby-cc')" = "claude-sandbox-ruby-2.6.10:latest" ]
  [ "$(run_core '_mysbx_preset_template omp')" = "" ]
}

@test "preset_kits omits atlassian under DEV_PERSONAL" {
  cd "$DEV_PERSONAL"
  run run_core "cd '$DEV_PERSONAL' && _mysbx_preset_kits cc"
  [[ "$output" != *atlassian* ]]
  [[ "$output" == *"/kits/personal"* ]]
}

@test "preset_kits includes atlassian off DEV_PERSONAL" {
  run run_core "cd '$TMP' && _mysbx_preset_kits cc"
  [[ "$output" == *"/kits/atlassian"* ]]
}

@test "name uses prefix + cwd basename" {
  run run_core "cd '$TMP' && _mysbx_name mysbx-cc"
  [ "$output" = "mysbx-cc-$(basename "$TMP")" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats extras/agent-sandboxing/tests/registry.bats`
Expected: FAIL ("command not found: _mysbx_is_preset").

- [ ] **Step 3: Add registry + naming to core lib**

Append to `extras/agent-sandboxing/lib/mysbx-core.zsh` (before the Dispatch section):
```zsh
# --- Preset registry --------------------------------------------------------
_MYSBX_KITS_TOOLING="$_AGENT_SBX_ROOT/kits/tooling"
_MYSBX_KITS_CLAUDE_PATCH="$_AGENT_SBX_ROOT/kits/claude-code-patch"
_MYSBX_KITS_PERSONAL="$_AGENT_SBX_ROOT/kits/personal"
_MYSBX_KITS_ATLASSIAN="$_AGENT_SBX_ROOT/kits/atlassian"
_MYSBX_KITS_OMP="$_AGENT_SBX_ROOT/kits/omp"

_mysbx_is_personal() { [[ "$PWD/" == "$DEV_PERSONAL/"* ]]; }

_mysbx_is_preset() {
  case "$1" in cc|ruby-cc|omp) return 0 ;; *) return 1 ;; esac
}

_mysbx_preset_agent() {
  case "$1" in
    cc|ruby-cc) echo claude ;;
    omp)        echo omp ;;
    *)          return 1 ;;
  esac
}

_mysbx_preset_template() {
  case "$1" in
    ruby-cc) echo "claude-sandbox-ruby-2.6.10:latest" ;;
    cc|omp)  echo "" ;;
    *)       return 1 ;;
  esac
}

# Echo kit dir paths (one per line) for a preset. atlassian appended only
# off-personal (matches the old dsbx-cc/omp behavior).
_mysbx_preset_kits() {
  local preset="$1"
  local -a kits=()
  case "$preset" in
    cc|ruby-cc)
      kits=("$_MYSBX_KITS_TOOLING" "$_MYSBX_KITS_CLAUDE_PATCH" "$_MYSBX_KITS_PERSONAL")
      _mysbx_is_personal || kits+=("$_MYSBX_KITS_ATLASSIAN")
      ;;
    omp)
      kits=("$_MYSBX_KITS_PERSONAL")
      _mysbx_is_personal || kits+=("$_MYSBX_KITS_ATLASSIAN")
      kits+=("$_MYSBX_KITS_OMP")
      ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${kits[@]}"
}

# --- Naming -----------------------------------------------------------------
# Build sandbox name from prefix, cwd, extra workspaces, and worktree source.
# (Ported from _dsbx_name, 20-dsbx.zsh:270-281.)
_mysbx_name() {
  local prefix="$1"; shift
  local name="${prefix}-$(basename "$(pwd)")"
  for ws in "$@"; do
    name="${name}--$(basename "${ws%:ro}")"
  done
  if _detect_git_worktree; then
    name="${name}--$(basename "$_GIT_WORKTREE_SOURCE_REPO")"
  fi
  echo "$name"
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bats extras/agent-sandboxing/tests/registry.bats`
Expected: all passing.

- [ ] **Step 5: Commit**

```bash
git add extras/agent-sandboxing/lib/mysbx-core.zsh extras/agent-sandboxing/tests/registry.bats
git commit -m "feat(mysbx): add preset registry and sandbox naming"
```

---

## Task 3: Secret sync

**Files:**
- Modify: `extras/agent-sandboxing/lib/mysbx-core.zsh`
- Create: `extras/agent-sandboxing/tests/helpers/stub-bin/op`
- Test: `extras/agent-sandboxing/tests/secrets.bats`

**Interfaces:**
- Consumes: `REAL_SBX`, `_MYSBX_STATE_DIR`, `_MYSBX_LOG`, `_MYSBX_SECRET_TTL`, `DEV_PERSONAL`, `GIT_TOKEN`, `GIT_TOKEN_PERSONAL`, `JIRA_USERNAME`.
- Produces:
  - `_mysbx_sync_github_secret <name>` → reads PAT via `op`, writes `$REAL_SBX secret set` via stdin; TTL-gated; returns non-zero on failure.
  - `_mysbx_sync_atlassian_secret <name>` → same for atlassian (global scope).
  - `_mysbx_sync_secrets <name>` → github always; atlassian only off-personal. Returns non-zero if any required sync fails (hard-fail).
  - `_mysbx_now_ms`, `_mysbx_time <label> cmd...` (timing/log).

- [ ] **Step 1: Write the stub `op`**

`extras/agent-sandboxing/tests/helpers/stub-bin/op`:
```bash
#!/usr/bin/env bash
# Stub 1Password CLI. `op read <path>` echoes a deterministic fake token unless
# STUB_OP_RC is nonzero (simulating a failed read).
if [ "${STUB_OP_RC:-0}" -ne 0 ]; then
  echo "stub op: forced failure" >&2
  exit "${STUB_OP_RC}"
fi
if [ "$1" = read ]; then
  echo "fake-token-for:$2"
fi
exit 0
```
Make executable: `chmod +x extras/agent-sandboxing/tests/helpers/stub-bin/op`

- [ ] **Step 2: Write the failing test**

`extras/agent-sandboxing/tests/secrets.bats`:
```bash
load helpers/setup
setup() { _mysbx_test_setup; }
teardown() { _mysbx_test_teardown; }

run_core() { zsh -c "source '$MYSBX_CORE'; _mysbx_load_config; _mysbx_resolve_real_sbx; $1"; }

@test "github sync writes secret via stdin, never argv" {
  run run_core "cd '$TMP' && _mysbx_sync_github_secret box1"
  [ "$status" -eq 0 ]
  # stub sbx recorded a `secret set ... github` call
  grep -qx github "$STUB_SBX_LOG"
  grep -qx 'secret' "$STUB_SBX_LOG"
  # token value must NOT appear in recorded argv
  ! grep -q 'fake-token-for' "$STUB_SBX_LOG"
}

@test "github sync uses global scope off-personal" {
  run run_core "cd '$TMP' && _mysbx_sync_github_secret box1"
  grep -qx -- '-g' "$STUB_SBX_LOG"
}

@test "github sync uses per-sandbox scope under DEV_PERSONAL" {
  run run_core "cd '$DEV_PERSONAL' && _mysbx_sync_github_secret box1"
  grep -qx box1 "$STUB_SBX_LOG"
  ! grep -qx -- '-g' "$STUB_SBX_LOG"
}

@test "github sync is TTL-gated (second call skips sbx)" {
  run_core "cd '$TMP' && _mysbx_sync_github_secret box1"
  : > "$STUB_SBX_LOG"
  run run_core "cd '$TMP' && _mysbx_sync_github_secret box1"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_SBX_LOG" ]
}

@test "github sync hard-fails when op read fails" {
  STUB_OP_RC=1 run run_core "cd '$TMP' && _mysbx_sync_github_secret box1"
  [ "$status" -ne 0 ]
}

@test "sync_secrets skips atlassian under DEV_PERSONAL" {
  run run_core "cd '$DEV_PERSONAL' && _mysbx_sync_secrets box1"
  [ "$status" -eq 0 ]
  ! grep -qx atlassian "$STUB_SBX_LOG"
}

@test "sync_secrets includes atlassian off-personal" {
  run run_core "cd '$TMP' && _mysbx_sync_secrets box1"
  [ "$status" -eq 0 ]
  grep -qx atlassian "$STUB_SBX_LOG"
}
```

- [ ] **Step 3: Run to verify failure**

Run: `bats extras/agent-sandboxing/tests/secrets.bats`
Expected: FAIL (functions undefined).

- [ ] **Step 4: Add secret sync to core lib**

Append to `extras/agent-sandboxing/lib/mysbx-core.zsh` (after Naming). This ports `_dsbx_*` from `20-dsbx.zsh:8-110` with the rename map and `sbx`→`$REAL_SBX`; the personal token path now comes from `$GIT_TOKEN_PERSONAL` (was hardcoded at `20-dsbx.zsh:34`):
```zsh
# --- Timing / log -----------------------------------------------------------
_mysbx_now_ms() { printf '%.0f\n' $(( EPOCHREALTIME * 1000 )); }
_mysbx_time() {
  local label="$1"; shift
  local start end rc
  start=$(_mysbx_now_ms)
  "$@"; rc=$?
  end=$(_mysbx_now_ms)
  echo "$(date -Iseconds) [timing] ${label}=$(( end - start ))ms rc=${rc}" >> "$_MYSBX_LOG"
  [ -n "${_MYSBX_PROFILE:-}" ] && echo "[mysbx] ${label}: $(( end - start ))ms" >&2
  return $rc
}

# --- Secret sync ------------------------------------------------------------
# Echo tab-delimited "<op_account>\t<op_path>\t<scope>" for the current cwd.
_mysbx_github_identity() {
  local sandbox_name="$1"
  case "$PWD/" in
    "$DEV_PERSONAL/"*)
      printf '%s\t%s\t%s\n' "my.1password.com" "$GIT_TOKEN_PERSONAL" "$sandbox_name" ;;
    *)
      printf '%s\t%s\t%s\n' "wellsky.1password.com" "$GIT_TOKEN" "-g" ;;
  esac
}

_mysbx_secret_marker() {
  local sandbox_name="$1" suffix="${2:-gh-secret}"
  echo "$_MYSBX_STATE_DIR/markers/${sandbox_name}.${suffix}"
}

_mysbx_secret_fresh() {
  local marker="$1"
  [ -f "$marker" ] || return 1
  local mtime; mtime=$(stat -f %m "$marker" 2>/dev/null) || return 1
  [ $(( $(date +%s) - mtime )) -lt $_MYSBX_SECRET_TTL ]
}

_mysbx_sync_github_secret() {
  local sandbox_name="$1"
  local marker; marker=$(_mysbx_secret_marker "$sandbox_name")
  _mysbx_secret_fresh "$marker" && return 0
  mkdir -p "$_MYSBX_STATE_DIR/markers"

  local op_account op_path scope
  IFS=$'\t' read -r op_account op_path scope <<< "$(_mysbx_github_identity "$sandbox_name")"

  local token
  if ! token=$(OP_ACCOUNT="$op_account" op read "$op_path" 2>>"$_MYSBX_LOG"); then
    echo "[mysbx] failed to read GitHub PAT from 1Password ($op_account: $op_path)" >&2
    echo "[mysbx] is your op session active? try: eval \$(op signin --account $op_account)" >&2
    return 1
  fi
  if ! printf '%s' "$token" | "$REAL_SBX" secret set "$scope" github -f >>"$_MYSBX_LOG" 2>&1; then
    echo "[mysbx] failed to write GitHub secret to sbx (scope=$scope)" >&2
    return 1
  fi
  touch "$marker"
}

_mysbx_sync_atlassian_secret() {
  local sandbox_name="$1"
  local marker; marker=$(_mysbx_secret_marker "$sandbox_name" "atlassian-secret")
  _mysbx_secret_fresh "$marker" && return 0
  mkdir -p "$_MYSBX_STATE_DIR/markers"

  local token
  if ! token=$(OP_ACCOUNT="wellsky.1password.com" op read "op://Employee/JIRA CLI Token/credential" 2>>"$_MYSBX_LOG"); then
    echo "[mysbx] failed to read Atlassian token from 1Password" >&2
    return 1
  fi
  local b64; b64=$(printf '%s:%s' "$JIRA_USERNAME" "$token" | base64)
  if ! printf '%s' "$b64" | "$REAL_SBX" secret set -g atlassian -f >>"$_MYSBX_LOG" 2>&1; then
    echo "[mysbx] failed to write Atlassian secret to sbx" >&2
    return 1
  fi
  touch "$marker"
}

# Sync all required secrets for a sandbox. Hard-fail on any failure.
_mysbx_sync_secrets() {
  local name="$1"
  _mysbx_time "sync-gh-secret($name)" _mysbx_sync_github_secret "$name" || return 1
  if ! _mysbx_is_personal; then
    _mysbx_time "sync-atlassian-secret($name)" _mysbx_sync_atlassian_secret "$name" || return 1
  fi
}
```
Note: the old code passed scope via an unquoted `$scope_arg` so `-g` split correctly; here `"$scope"` is a single token (`-g` or the sandbox name) and is always one argument — correct for both `secret set -g github` and `secret set <name> github`.

- [ ] **Step 5: Run to verify pass**

Run: `bats extras/agent-sandboxing/tests/secrets.bats`
Expected: all passing.

- [ ] **Step 6: Commit**

```bash
git add extras/agent-sandboxing/lib/mysbx-core.zsh extras/agent-sandboxing/tests/secrets.bats \
  extras/agent-sandboxing/tests/helpers/stub-bin/op
git commit -m "feat(mysbx): port secret sync with hard-fail wrapper"
```

---

## Task 4: Helper mounts

**Files:**
- Modify: `extras/agent-sandboxing/lib/mysbx-core.zsh`
- Test: `extras/agent-sandboxing/tests/mounts.bats`

**Interfaces:**
- Consumes: `DEV_PERSONAL`, `XDG_CACHE_HOME`, `REAL_SBX`.
- Produces:
  - Globals `_MYSBX_HELPER_ADC_DIR`, `_MYSBX_HELPER_PLUGINS_DIR`, `_MYSBX_HELPER_DOTFILES_DIR`, `_MYSBX_OMP_FORK_HOST_DIR`, `_MYSBX_OMP_FORK_CACHE_DIR`, `_MYSBX_OMP_FORK_BUN_VOLUME`, `_MYSBX_OMP_FORK_CARGO_VOLUME`.
  - `_mysbx_helper_mounts <sandbox_state_dir>` → echoes mount specs (one/line); skips missing dirs and dirs containing cwd.
  - `_mysbx_helper_mounts_stale <name> <expected...>` → 0 if any expected mount absent from the live sandbox.

- [ ] **Step 1: Write the failing test**

`extras/agent-sandboxing/tests/mounts.bats`:
```bash
load helpers/setup
setup() { _mysbx_test_setup; }
teardown() { _mysbx_test_teardown; }

run_core() { zsh -c "source '$MYSBX_CORE'; _mysbx_load_config; $1"; }

@test "helper mounts include existing state dir, skip missing dirs" {
  local state="$TMP/state/box"
  mkdir -p "$state"
  run run_core "cd '$TMP' && _mysbx_helper_mounts '$state'"
  [[ "$output" == *"$state"* ]]
}

@test "helper mounts skip a candidate that contains cwd" {
  # dotfiles dir = DEV_PERSONAL/dotfiles; cwd inside it must be excluded
  local df="$DEV_PERSONAL/dotfiles"; mkdir -p "$df/sub"
  run run_core "cd '$df/sub' && _MYSBX_HELPER_DOTFILES_DIR='$df' _mysbx_helper_mounts '$TMP/state/box'"
  [[ "$output" != *"$df:ro"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats extras/agent-sandboxing/tests/mounts.bats`
Expected: FAIL (functions undefined).

- [ ] **Step 3: Add helper mounts to core lib**

Append to `extras/agent-sandboxing/lib/mysbx-core.zsh` (ports `20-dsbx.zsh:132-183`, rename map + `sbx`→`$REAL_SBX`):
```zsh
# --- Helper bind mounts -----------------------------------------------------
_MYSBX_HELPER_ADC_DIR="$HOME/.config/gcloud"
_MYSBX_HELPER_PLUGINS_DIR="$HOME/.claude/plugins"
_MYSBX_HELPER_DOTFILES_DIR="$DEV_PERSONAL/dotfiles"
_MYSBX_OMP_FORK_HOST_DIR="$DEV_PERSONAL/oh-my-pi-personal-build"
_MYSBX_OMP_FORK_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/mysbx/omp-fork"
_MYSBX_OMP_FORK_BUN_VOLUME="mysbx-omp-fork-buncache"
_MYSBX_OMP_FORK_CARGO_VOLUME="mysbx-omp-fork-cargocache"

# Echo read-only helper mount specs (host path[:ro]) for `sbx create`. Skips
# missing dirs and any candidate dir that contains the cwd.
_mysbx_helper_mounts() {
  local sandbox_state="$1"
  local -a mounts=()
  local cwd; cwd="$(pwd -P)"
  local -a candidates=(
    "${_MYSBX_HELPER_ADC_DIR}:ro"
    "${_MYSBX_HELPER_PLUGINS_DIR}:ro"
    "${_MYSBX_HELPER_DOTFILES_DIR}:ro"
    "${_MYSBX_OMP_FORK_CACHE_DIR}:ro"
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

# 0 (true) if the live sandbox is missing any expected helper mount.
_mysbx_helper_mounts_stale() {
  local name="$1"; shift
  local -a expected=("$@")
  (( ${#expected[@]} )) || return 1
  local actual
  actual=$("$REAL_SBX" ls --json 2>/dev/null \
    | jq -r --arg n "$name" '.sandboxes[] | select(.name==$n) | .workspaces[]') || return 1
  local m
  for m in "${expected[@]}"; do
    grep -qxF -- "$m" <<< "$actual" || return 0
  done
  return 1
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bats extras/agent-sandboxing/tests/mounts.bats`
Expected: all passing.

- [ ] **Step 5: Commit**

```bash
git add extras/agent-sandboxing/lib/mysbx-core.zsh extras/agent-sandboxing/tests/mounts.bats
git commit -m "feat(mysbx): port helper bind mounts"
```

---

## Task 5: Augmented create/run dispatch

**Files:**
- Modify: `extras/agent-sandboxing/lib/mysbx-core.zsh` (purge-orphans, augmented create, dispatch)
- Test: `extras/agent-sandboxing/tests/create.bats`

**Interfaces:**
- Consumes: registry, naming, secrets, mounts, `REAL_SBX`, `_MYSBX_STATE_DIR`.
- Produces:
  - `_mysbx_purge_orphans <name>` (best-effort containerd cleanup).
  - `_mysbx_augmented_create <verb> <preset> <rest...>` — assemble `$REAL_SBX <verb> [-t tmpl] [--name <derived-if-no-name>] --kit … <real-agent> <rest…> <helper-mounts…>`, sync secrets first (hard-fail), retry once after purge on create failure. Honors `--name`, `--clone`, worktree source mount.
  - `mysbx_dispatch` updated: `create`/`run` inspect agent positional; preset → `_mysbx_augmented_create`; else vanilla forward.

- [ ] **Step 1: Write the failing test**

`extras/agent-sandboxing/tests/create.bats`:
```bash
load helpers/setup
setup() { _mysbx_test_setup; }
teardown() { _mysbx_test_teardown; }

@test "create with preset cc expands agent and injects kits + name" {
  ( cd "$TMP" && zsh "$MYSBX" create cc . )
  local argv; argv="$(sbx_argv)"
  grep -qx create <<<"$argv"
  grep -qx claude <<<"$argv"          # preset cc -> real agent claude
  ! grep -qx cc <<<"$argv"            # preset token not forwarded as agent
  grep -qx -- '--kit' <<<"$argv"
  grep -qx -- '--name' <<<"$argv"
  grep -q "mysbx-cc-$(basename "$TMP")" <<<"$argv"
}

@test "create with real agent claude forwards vanilla (no kits)" {
  ( cd "$TMP" && zsh "$MYSBX" create claude . )
  local argv; argv="$(sbx_argv)"
  grep -qx create <<<"$argv"
  grep -qx claude <<<"$argv"
  ! grep -qx -- '--kit' <<<"$argv"
}

@test "create with preset omp expands to omp agent" {
  ( cd "$TMP" && zsh "$MYSBX" create omp . )
  local argv; argv="$(sbx_argv)"
  grep -qx omp <<<"$argv"
  grep -qx -- '--kit' <<<"$argv"
}

@test "create ruby-cc passes template -t" {
  ( cd "$TMP" && zsh "$MYSBX" create ruby-cc . )
  local argv; argv="$(sbx_argv)"
  grep -qx -- '-t' <<<"$argv"
  grep -qx 'claude-sandbox-ruby-2.6.10:latest' <<<"$argv"
}

@test "create --clone reaches real sbx" {
  ( cd "$TMP" && zsh "$MYSBX" create cc --clone . )
  grep -qx -- '--clone' "$STUB_SBX_LOG"
}

@test "explicit --name overrides derived name" {
  ( cd "$TMP" && zsh "$MYSBX" create cc . --name custombox )
  grep -qx custombox "$STUB_SBX_LOG"
  ! grep -q "mysbx-cc-" "$STUB_SBX_LOG"
}

@test "create hard-fails when secret sync fails" {
  STUB_OP_RC=1 run zsh -c "cd '$TMP' && '$MYSBX' create cc ."
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats extras/agent-sandboxing/tests/create.bats`
Expected: FAIL (augmentation not wired; `create cc` currently forwards `cc` verbatim).

- [ ] **Step 3: Add purge-orphans + augmented create + dispatch**

Append to `extras/agent-sandboxing/lib/mysbx-core.zsh` (purge ports `20-dsbx.zsh:283-293`):
```zsh
# --- Orphan cleanup ---------------------------------------------------------
_MYSBX_SBXD_SOCK="$HOME/Library/Application Support/com.docker.sandboxes/sandboxes/sandboxd/docker.sock"
_mysbx_purge_orphans() {
  local name="$1"
  [ -S "$_MYSBX_SBXD_SOCK" ] || return 0
  docker -H "unix://$_MYSBX_SBXD_SOCK" rm -f "$name" >> "$_MYSBX_LOG" 2>&1 || true
  docker -H "unix://$_MYSBX_SBXD_SOCK" network rm "$name" >> "$_MYSBX_LOG" 2>&1 || true
}

# --- Augmented create/run ---------------------------------------------------
# _mysbx_augmented_create <verb> <preset> <rest...>
# <rest...> is everything after the agent positional (workdir, flags). We parse
# out --name (honor if present) and --clone (forward), derive the name and
# helper mounts, sync secrets (hard-fail), then invoke real sbx with one retry.
_mysbx_augmented_create() {
  local verb="$1" preset="$2"; shift 2
  local agent template
  agent="$(_mysbx_preset_agent "$preset")"
  template="$(_mysbx_preset_template "$preset")"

  # Split rest into: explicit name (if any), clone flag, and remaining args
  # (workdir + extra workspaces + passthrough flags).
  local explicit_name="" clone=0
  local -a rest=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --name) explicit_name="$2"; shift 2 ;;
      --name=*) explicit_name="${1#--name=}"; shift ;;
      --clone) clone=1; shift ;;
      *) rest+=("$1"); shift ;;
    esac
  done

  # Worktree source mount (extra workspace) participates in naming.
  local -a extra_ws=()
  if _detect_git_worktree; then
    extra_ws+=("$_GIT_WORKTREE_SOURCE_REPO")
  fi

  local name
  if [[ -n "$explicit_name" ]]; then
    name="$explicit_name"
  else
    name="$(_mysbx_name "mysbx-$preset" "${extra_ws[@]}")"
  fi

  local sandbox_state_dir="$_MYSBX_STATE_DIR/sandboxes/$name"
  mkdir -p "$sandbox_state_dir"/{sessions,plans,projects}
  [ -f "$sandbox_state_dir/history.jsonl" ] || touch "$sandbox_state_dir/history.jsonl"

  local -a helper_mounts=()
  helper_mounts=(${(f)"$(_mysbx_helper_mounts "$sandbox_state_dir")"})

  local -a kit_args=() tmpl_args=() clone_args=()
  local k
  while IFS= read -r k; do [[ -n "$k" ]] && kit_args+=(--kit "$k"); done \
    < <(_mysbx_preset_kits "$preset")
  [[ -n "$template" ]] && tmpl_args=(-t "$template")
  (( clone )) && clone_args=(--clone)

  # Secrets must be in place before the sandbox runs git. Hard-fail.
  _mysbx_sync_secrets "$name" || return 1

  local -a cmd=("$verb" "${tmpl_args[@]}" --name "$name" "${kit_args[@]}" \
    "${clone_args[@]}" "$agent" "${rest[@]}" "${extra_ws[@]}" "${helper_mounts[@]}")
  if ! "$REAL_SBX" "${cmd[@]}" 2> >(tee -a "$_MYSBX_LOG" >&2) >> "$_MYSBX_LOG"; then
    echo "$(date -Iseconds) Create failed; purging orphans and retrying $name" >> "$_MYSBX_LOG"
    _mysbx_purge_orphans "$name"
    "$REAL_SBX" "${cmd[@]}" 2> >(tee -a "$_MYSBX_LOG" >&2) >> "$_MYSBX_LOG" || {
      echo "[mysbx] sbx $verb failed for $name (see $_MYSBX_LOG)" >&2
      return 1
    }
  fi
}
```

Replace the `mysbx_dispatch` function with:
```zsh
# --- Dispatch ---------------------------------------------------------------
mysbx_dispatch() {
  _mysbx_load_config
  _mysbx_resolve_real_sbx || return 1
  local verb="${1:-}"
  case "$verb" in
    "" ) exec "$REAL_SBX" ;;
    create|run)
      shift
      # Agent positional is the first non-flag token. Peek without consuming.
      local agent_pos=""
      local a
      for a in "$@"; do
        case "$a" in
          -*) continue ;;        # skip leading flags
          *) agent_pos="$a"; break ;;
        esac
      done
      if _mysbx_is_preset "$agent_pos"; then
        # Re-split: drop the agent positional, keep everything else as rest.
        local -a rest=(); local dropped=0
        for a in "$@"; do
          if (( ! dropped )) && [[ "$a" == "$agent_pos" ]]; then dropped=1; continue; fi
          rest+=("$a")
        done
        _mysbx_augmented_create "$verb" "$agent_pos" "${rest[@]}"
        return $?
      fi
      exec "$REAL_SBX" "$verb" "$@"
      ;;
    * ) exec "$REAL_SBX" "$@" ;;
  esac
}
```
Note: the augmented branch cannot `exec` (it runs secret sync first and must inspect the return code), so it returns. The vanilla branches `exec` for a clean process replacement.

- [ ] **Step 4: Run to verify pass**

Run: `bats extras/agent-sandboxing/tests/create.bats`
Expected: all passing.

- [ ] **Step 5: Run the full suite (no regressions)**

Run: `bats extras/agent-sandboxing/tests`
Expected: all passing.

- [ ] **Step 6: Commit**

```bash
git add extras/agent-sandboxing/lib/mysbx-core.zsh extras/agent-sandboxing/tests/create.bats
git commit -m "feat(mysbx): augmented create/run for preset agents"
```

---

## Task 6: exec dispatch (secret resync + forward)

**Files:**
- Modify: `extras/agent-sandboxing/lib/mysbx-core.zsh`
- Test: `extras/agent-sandboxing/tests/exec.bats`

**Interfaces:**
- Consumes: `_mysbx_sync_secrets`, `REAL_SBX`.
- Produces: `mysbx_dispatch` handles `exec`: resync secrets for the named sandbox (TTL-gated; warn-but-continue if sync fails, since the sandbox already exists), then forward verbatim.

- [ ] **Step 1: Write the failing test**

`extras/agent-sandboxing/tests/exec.bats`:
```bash
load helpers/setup
setup() { _mysbx_test_setup; }
teardown() { _mysbx_test_teardown; }

@test "exec resyncs secret then forwards verbatim" {
  ( cd "$TMP" && zsh "$MYSBX" exec mybox -- claude -p hi )
  local argv; argv="$(sbx_argv)"
  grep -qx exec <<<"$argv"
  grep -qx mybox <<<"$argv"
  grep -qx claude <<<"$argv"
  grep -qx github <<<"$argv"     # secret resynced via stub sbx
}

@test "exec still forwards when secret resync fails (sandbox exists)" {
  STUB_OP_RC=1 run zsh -c "cd '$TMP' && '$MYSBX' exec mybox -- claude"
  [ "$status" -eq 0 ]
  grep -qx exec "$STUB_SBX_LOG"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats extras/agent-sandboxing/tests/exec.bats`
Expected: FAIL (test 1 — `github` not in argv because `exec` currently forwards without resync).

- [ ] **Step 3: Add exec handling to dispatch**

In `mysbx_dispatch`, add a case before the final `*`:
```zsh
    exec)
      local name="${2:-}"
      if [[ -n "$name" && "$name" != -* ]]; then
        _mysbx_sync_secrets "$name" || \
          echo "[mysbx] secret resync failed for $name; continuing" >&2
      fi
      exec "$REAL_SBX" "$@"
      ;;
```

- [ ] **Step 4: Run to verify pass**

Run: `bats extras/agent-sandboxing/tests/exec.bats`
Expected: all passing.

- [ ] **Step 5: Commit**

```bash
git add extras/agent-sandboxing/lib/mysbx-core.zsh extras/agent-sandboxing/tests/exec.bats
git commit -m "feat(mysbx): resync secrets on exec then forward"
```

---

## Task 7: Custom verbs (build, omp-build, omp-clean, update, check)

**Files:**
- Modify: `extras/agent-sandboxing/lib/mysbx-core.zsh`
- Test: `extras/agent-sandboxing/tests/custom-verbs.bats`

**Interfaces:**
- Consumes: `REAL_SBX`, mount/registry globals, `_MYSBX_OMP_FORK_*`.
- Produces:
  - `_mysbx_build`, `_mysbx_omp_build`, `_mysbx_omp_clean`, `_mysbx_update`, `_mysbx_check` (ported from `dsbx-build`/`dsbx-omp-build`/`dsbx-omp-clean`/`dsbx-update`/`dsbx-check`).
  - `_MYSBX_TEMPLATES_DIR` global.
  - `mysbx_dispatch` routes verbs `build|omp-build|omp-clean|update|check|secrets-sync` to these (never forwarded).

- [ ] **Step 1: Write the failing test**

These are heavy docker/sbx operations; unit-test the *dispatch routing* (that the verbs are handled locally, not forwarded to real sbx) using a stub `docker`. Full behavior is verified manually in Task 9.

`extras/agent-sandboxing/tests/helpers/stub-bin/docker`:
```bash
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "${STUB_DOCKER_LOG:-/dev/null}"
# `compose ... config --images` must print something iterable.
if [ "$1" = compose ] && [[ "$*" == *"config --images"* ]]; then
  echo "claude-sandbox-mise:latest"
fi
exit 0
```
Make executable: `chmod +x extras/agent-sandboxing/tests/helpers/stub-bin/docker`

`extras/agent-sandboxing/tests/custom-verbs.bats`:
```bash
load helpers/setup
setup() {
  _mysbx_test_setup
  export STUB_DOCKER_LOG="$TMP/docker.log"; : > "$STUB_DOCKER_LOG"
}
teardown() { _mysbx_test_teardown; }

@test "build verb is handled locally, not forwarded to sbx as 'build'" {
  ( cd "$TMP" && zsh "$MYSBX" build claude-sandbox-mise )
  # real sbx never receives a literal 'build' verb
  ! grep -qx build "$STUB_SBX_LOG"
  # docker compose build was invoked
  grep -q 'compose' "$STUB_DOCKER_LOG"
}

@test "omp-clean verb handled locally" {
  run zsh -c "cd '$TMP' && '$MYSBX' omp-clean"
  [ "$status" -eq 0 ]
  ! grep -qx omp-clean "$STUB_SBX_LOG"
}

@test "secrets-sync verb syncs without forwarding" {
  ( cd "$TMP" && zsh "$MYSBX" secrets-sync mybox )
  grep -qx github "$STUB_SBX_LOG"
  ! grep -qx secrets-sync "$STUB_SBX_LOG"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `bats extras/agent-sandboxing/tests/custom-verbs.bats`
Expected: FAIL (verbs currently forwarded to real sbx).

- [ ] **Step 3: Port custom-verb implementations**

Append to `extras/agent-sandboxing/lib/mysbx-core.zsh`. Port the five functions from `20-dsbx.zsh` applying the rename map (`dsbx`→`mysbx`, `_DSBX_`→`_MYSBX_`, `sbx`→`$REAL_SBX`, `_dsbx_name`→`_mysbx_name`), with these exact source ranges and definitions:

```zsh
# --- Custom verbs -----------------------------------------------------------
_MYSBX_TEMPLATES_DIR="$_AGENT_SBX_ROOT/templates"

# Ported from dsbx-build (20-dsbx.zsh:112-125).
_mysbx_build() {
  docker compose -f "$_MYSBX_TEMPLATES_DIR/docker-compose.yml" build "$@" && \
  for img in $(docker compose -f "$_MYSBX_TEMPLATES_DIR/docker-compose.yml" config --images); do
    echo "Loading $img into sbx..." && \
    docker save "$img" | "$REAL_SBX" template load /dev/stdin
  done || return
  if [ -d "$_MYSBX_OMP_FORK_HOST_DIR" ] && { [ $# -eq 0 ] || (( ${@[(I)omp-sandbox]} )); }; then
    echo "[mysbx build] chaining omp-build" >&2
    _mysbx_omp_build
  fi
}

# Ported from dsbx-omp-build (20-dsbx.zsh:210-257) — body unchanged except the
# rename map. Copy that function verbatim, renaming identifiers:
_mysbx_omp_build() {
  if [ ! -d "$_MYSBX_OMP_FORK_HOST_DIR" ]; then
    echo "[mysbx omp-build] fork worktree missing: $_MYSBX_OMP_FORK_HOST_DIR" >&2
    return 1
  fi
  if ! docker image inspect omp-sandbox:latest >/dev/null 2>&1; then
    echo "[mysbx omp-build] omp-sandbox:latest not built; run 'mysbx build omp-sandbox' first" >&2
    return 1
  fi
  mkdir -p "$_MYSBX_OMP_FORK_CACHE_DIR"
  docker volume inspect "$_MYSBX_OMP_FORK_BUN_VOLUME" >/dev/null 2>&1 || \
    docker volume create "$_MYSBX_OMP_FORK_BUN_VOLUME" >/dev/null
  docker volume inspect "$_MYSBX_OMP_FORK_CARGO_VOLUME" >/dev/null 2>&1 || \
    docker volume create "$_MYSBX_OMP_FORK_CARGO_VOLUME" >/dev/null
  local host_hash=""
  if command -v git >/dev/null 2>&1; then
    host_hash=$(git -C "$_MYSBX_OMP_FORK_HOST_DIR" rev-parse HEAD 2>/dev/null || true)
  fi
  echo "[mysbx omp-build] building $_MYSBX_OMP_FORK_HOST_DIR ${host_hash:+@ $host_hash} -> $_MYSBX_OMP_FORK_CACHE_DIR" >&2
  docker run --rm \
    -v "$_MYSBX_OMP_FORK_HOST_DIR:/src:ro" \
    -v "$_MYSBX_OMP_FORK_CACHE_DIR:/out" \
    -v "$_MYSBX_OMP_FORK_BUN_VOLUME:/root/.bun/install/cache" \
    -v "$_MYSBX_OMP_FORK_CARGO_VOLUME:/usr/local/cargo-cache" \
    -e CARGO_HOME=/usr/local/cargo-cache \
    -e CARGO_TARGET_DIR=/usr/local/cargo-cache/target \
    -e HOST_HASH="$host_hash" \
    --user 0:0 \
    omp-sandbox:latest bash -c '\
      set -euo pipefail; \
      rsync -a --delete \
        --exclude=.git --exclude=node_modules --exclude=target \
        --exclude="packages/natives/native/*.node" \
        /src/ /out/; \
      cd /out; \
      echo "[mysbx omp-build] bun install" >&2; \
      bun install --frozen-lockfile || bun install; \
      echo "[mysbx omp-build] cargo build linux-arm64 native" >&2; \
      bun run --cwd packages/natives build; \
      printf "%s\n" "$HOST_HASH" > /out/.mysbx-fork-hash; \
      echo "[mysbx omp-build] ready @ ${HOST_HASH:-unknown}" >&2; \
    '
}

# Ported from dsbx-omp-clean (20-dsbx.zsh:261-267).
_mysbx_omp_clean() {
  rm -rf "$_MYSBX_OMP_FORK_CACHE_DIR"
  if [ "${1:-}" = --all ]; then
    docker volume rm -f "$_MYSBX_OMP_FORK_BUN_VOLUME" "$_MYSBX_OMP_FORK_CARGO_VOLUME" >/dev/null 2>&1 || true
  fi
  echo "[mysbx omp-clean] removed $_MYSBX_OMP_FORK_CACHE_DIR${1:+ + named volumes}" >&2
}

# Ported from dsbx-update (20-dsbx.zsh:412-431). Prefixes are now mysbx-*.
_mysbx_update() {
  local -a prefixes=(mysbx-cc mysbx-ruby-cc mysbx-omp)
  local -a kits=("$_MYSBX_KITS_TOOLING" "$_MYSBX_KITS_CLAUDE_PATCH" "$_MYSBX_KITS_PERSONAL")
  _mysbx_is_personal || kits+=("$_MYSBX_KITS_ATLASSIAN")
  local found=0 prefix name kit
  for prefix in "${prefixes[@]}"; do
    name="$(_mysbx_name "$prefix")"
    "$REAL_SBX" ls 2>/dev/null | awk '{print $1}' | grep -qx "$name" || continue
    found=1
    for kit in "${kits[@]}"; do
      echo "[mysbx] applying $(basename "$kit") to $name" >&2
      "$REAL_SBX" kit add "$name" "$kit"
    done
  done
  (( found )) || { echo "[mysbx] no sandboxes found for this directory" >&2; return 1; }
}

# Ported from dsbx-check (20-dsbx.zsh:438-475). Prefixes/recreate hint mysbx-*.
_mysbx_check() {
  local -a entries=(
    'mysbx-ruby-cc:claude-sandbox-ruby-2.6.10:latest'
    'mysbx-omp:omp-sandbox:latest'
  )
  local rc=0 found=0 entry prefix img name container_id current_id
  for entry in "${entries[@]}"; do
    prefix="${entry%%:*}"; img="${entry#*:}"
    name="$(_mysbx_name "$prefix")"
    "$REAL_SBX" ls 2>/dev/null | awk '{print $1}' | grep -qx "$name" || continue
    found=1
    container_id=$(docker -H "unix://$_MYSBX_SBXD_SOCK" inspect "$name" --format '{{.Image}}' 2>/dev/null \
      | sed 's/^sha256:\(.\{12\}\).*/\1/')
    current_id=$(docker image inspect --format '{{.Id}}' "$img" 2>/dev/null \
      | sed 's/^sha256:\(.\{12\}\).*/\1/')
    if [ -z "$current_id" ]; then
      printf 'missing-image    %s  (sandbox=%s; run mysbx build)\n' "$img" "$name"; rc=1
    elif [ -z "$container_id" ]; then
      printf 'unknown          %s  (could not inspect container; sbx daemon down?)\n' "$name"; rc=1
    elif [ "$container_id" = "$current_id" ]; then
      printf 'ok               %s  %s  (%s)\n' "$name" "$container_id" "$img"
    else
      printf 'stale            %s  running=%s  current=%s  (recreate: mysbx-%s --recreate)\n' \
        "$name" "$container_id" "$current_id" "${prefix#mysbx-}"; rc=1
    fi
  done
  (( found )) || echo 'no sandboxes for this cwd'
  return $rc
}
```

In `mysbx_dispatch`, add before the final `*` case:
```zsh
    build)        shift; _mysbx_build "$@"; return $? ;;
    omp-build)    shift; _mysbx_omp_build "$@"; return $? ;;
    omp-clean)    shift; _mysbx_omp_clean "$@"; return $? ;;
    update)       shift; _mysbx_update "$@"; return $? ;;
    check)        shift; _mysbx_check "$@"; return $? ;;
    secrets-sync) shift; _mysbx_sync_secrets "${1:?usage: mysbx secrets-sync <name>}"; return $? ;;
```

- [ ] **Step 4: Run to verify pass**

Run: `bats extras/agent-sandboxing/tests/custom-verbs.bats`
Expected: all passing.

- [ ] **Step 5: Commit**

```bash
git add extras/agent-sandboxing/lib/mysbx-core.zsh extras/agent-sandboxing/tests/custom-verbs.bats \
  extras/agent-sandboxing/tests/helpers/stub-bin/docker
git commit -m "feat(mysbx): port custom verbs (build/omp/update/check)"
```

---

## Task 8: Interactive file — all-in-one launch + thin aliases

**Files:**
- Create: `extras/agent-sandboxing/20-mysbx.zsh`
- Modify: `extras/agent-sandboxing/lib/mysbx-core.zsh` (add `_mysbx_launch`)
- Test: `extras/agent-sandboxing/tests/launch.bats`

**Interfaces:**
- Consumes: all core functions.
- Produces:
  - `_mysbx_launch <preset> [user_args...]` — interactive all-in-one: derive name, create-if-needed (with stale-mount auto-recreate + `--recreate`), sync secrets, then `sbx exec -i <name> -- <agent> -p <prompt>` for `--print`/`-p`, else `sbx run <agent> --name <name>`. Ported from `_dsbx_run` (`20-dsbx.zsh:309-384`).
  - `20-mysbx.zsh` sources core and defines `mysbx-cc`, `mysbx-ruby-cc`, `mysbx-omp` (call `_mysbx_launch`), plus thin `mysbx-build/check/update/omp-build/omp-clean` (call `_mysbx_*`).

- [ ] **Step 1: Write the failing test**

`extras/agent-sandboxing/tests/launch.bats`:
```bash
load helpers/setup
setup() {
  _mysbx_test_setup
  # _mysbx_launch's interactive run/exec must not block tests: stub sbx exits 0.
  SRC="source '$MYSBX_CORE'; source '$SBX_ROOT/20-mysbx.zsh'; _mysbx_load_config; _mysbx_resolve_real_sbx;"
}
teardown() { _mysbx_test_teardown; }

@test "interactive functions are defined after sourcing" {
  run zsh -c "$SRC functions mysbx-cc >/dev/null && functions mysbx-omp >/dev/null && echo ok"
  [ "$output" = ok ]
}

@test "launch creates when sandbox absent, then runs" {
  # stub ls returns empty -> not found -> create path taken
  STUB_SBX_LS_OUTPUT="" run zsh -c "$SRC cd '$TMP' && _mysbx_launch cc"
  [ "$status" -eq 0 ]
  grep -qx create "$STUB_SBX_LOG"
  grep -qx run "$STUB_SBX_LOG"
}

@test "launch skips create when sandbox present" {
  local name="mysbx-cc-$(basename "$TMP")"
  STUB_SBX_LS_OUTPUT="$name" run zsh -c "$SRC cd '$TMP' && _mysbx_launch cc"
  [ "$status" -eq 0 ]
  ! grep -qx create "$STUB_SBX_LOG"
  grep -qx run "$STUB_SBX_LOG"
}

@test "launch with -p uses exec path with prompt" {
  STUB_SBX_LS_OUTPUT="" run zsh -c "$SRC cd '$TMP' && _mysbx_launch cc -p 'do a thing'"
  grep -qx exec "$STUB_SBX_LOG"
  grep -qx -- '-p' "$STUB_SBX_LOG"
}
```
Note: the stub `sbx ls` prints `$STUB_SBX_LS_OUTPUT`; `_mysbx_launch`'s existence check greps that. `_mysbx_helper_mounts_stale` calls `sbx ls --json | jq`; with the stub printing a bare name (not JSON) `jq` fails → `_mysbx_helper_mounts_stale` returns non-zero (not stale) → no spurious recreate. Acceptable for the test.

- [ ] **Step 2: Run to verify failure**

Run: `bats extras/agent-sandboxing/tests/launch.bats`
Expected: FAIL (`_mysbx_launch`/`mysbx-cc` undefined).

- [ ] **Step 3: Add `_mysbx_launch` to core lib**

Append to `extras/agent-sandboxing/lib/mysbx-core.zsh`. This ports `_dsbx_run` (`20-dsbx.zsh:309-384`) but takes a preset (resolving agent/template/kits/print_cmd via the registry instead of positional args). `print_cmd` is the real agent binary name (`claude`/`omp`):
```zsh
# --- Interactive all-in-one launch (not used by the executable) -------------
# _mysbx_launch <preset> [user_args...]
# Flags in user_args: --recreate (tear down first), --print|-p (exec agent -p
# <prompt> instead of interactive run; remaining positionals = prompt).
_mysbx_launch() {
  local preset="$1"; shift
  local agent template print_cmd
  agent="$(_mysbx_preset_agent "$preset")"
  template="$(_mysbx_preset_template "$preset")"
  print_cmd="$agent"

  local -a kits=()
  local k
  while IFS= read -r k; do [[ -n "$k" ]] && kits+=("$k"); done \
    < <(_mysbx_preset_kits "$preset")

  local recreate=0 print_mode=0
  local -a positional=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      --recreate) recreate=1 ;;
      --print|-p) print_mode=1 ;;
      *) positional+=("$arg") ;;
    esac
  done
  local -a extra_ws=() agent_args=()
  if (( print_mode )); then
    agent_args=("${positional[@]}")
  else
    extra_ws=("${positional[@]}")
  fi
  if _detect_git_worktree; then
    extra_ws+=("$_GIT_WORKTREE_SOURCE_REPO")
  fi

  local name; name="$(_mysbx_name "mysbx-$preset" "${extra_ws[@]}")"
  local sandbox_state_dir="$_MYSBX_STATE_DIR/sandboxes/$name"
  mkdir -p "$sandbox_state_dir"/{sessions,plans,projects}
  [ -f "$sandbox_state_dir/history.jsonl" ] || touch "$sandbox_state_dir/history.jsonl"
  local -a helper_mounts=()
  helper_mounts=(${(f)"$(_mysbx_helper_mounts "$sandbox_state_dir")"})

  if ! (( recreate )) && "$REAL_SBX" ls 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
    if _mysbx_helper_mounts_stale "$name" "${helper_mounts[@]}"; then
      echo "$(date -Iseconds) Helper mounts stale on $name, auto-recreating" >> "$_MYSBX_LOG"
      recreate=1
    fi
  fi
  if (( recreate )); then
    echo "$(date -Iseconds) Recreating $name" >> "$_MYSBX_LOG"
    "$REAL_SBX" rm -f "$name" >> "$_MYSBX_LOG" 2>&1 || true
    _mysbx_purge_orphans "$name"
    rm -f "$_MYSBX_STATE_DIR/markers/${name}".{gh,atlassian}-secret
  fi
  if ! "$REAL_SBX" ls 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
    echo "$(date -Iseconds) Creating $name" >> "$_MYSBX_LOG"
    local -a kit_args=() tmpl_args=()
    for k in "${kits[@]}"; do kit_args+=(--kit "$k"); done
    [[ -n "$template" ]] && tmpl_args=(-t "$template")
    if ! "$REAL_SBX" create "${tmpl_args[@]}" --name "$name" "${kit_args[@]}" \
        "$agent" . "${extra_ws[@]}" "${helper_mounts[@]}" 2> >(tee -a "$_MYSBX_LOG" >&2) >> "$_MYSBX_LOG"; then
      echo "$(date -Iseconds) Create failed; purging orphans and retrying $name" >> "$_MYSBX_LOG"
      _mysbx_purge_orphans "$name"
      if ! "$REAL_SBX" create "${tmpl_args[@]}" --name "$name" "${kit_args[@]}" \
          "$agent" . "${extra_ws[@]}" "${helper_mounts[@]}" 2> >(tee -a "$_MYSBX_LOG" >&2) >> "$_MYSBX_LOG"; then
        echo "[mysbx] sbx create failed for $name (see $_MYSBX_LOG)" >&2
        return 1
      fi
    fi
  fi
  _mysbx_sync_secrets "$name" || return 1
  if (( print_mode )); then
    "$REAL_SBX" exec -i "$name" -- "$print_cmd" -p "${agent_args[@]}"
    return $?
  fi
  "$REAL_SBX" run "$agent" --name "$name"
}
```

- [ ] **Step 4: Write the interactive file**

`extras/agent-sandboxing/20-mysbx.zsh`:
```zsh
# mysbx interactive launchers. Sourced via init.zsh from .zshrc.
# The executable (~/.local/bin/mysbx) is the non-interactive entry point; these
# functions add the all-in-one create-if-needed convenience for interactive use.
source "${0:A:h}/lib/mysbx-core.zsh"
_mysbx_load_config
_mysbx_resolve_real_sbx || return

mysbx-cc()      { _mysbx_launch cc "$@"; }
mysbx-ruby-cc() { _mysbx_launch ruby-cc "$@"; }
mysbx-omp()     { _mysbx_launch omp "$@"; }

mysbx-build()     { _mysbx_build "$@"; }
mysbx-omp-build() { _mysbx_omp_build "$@"; }
mysbx-omp-clean() { _mysbx_omp_clean "$@"; }
mysbx-update()    { _mysbx_update "$@"; }
mysbx-check()     { _mysbx_check "$@"; }
```

- [ ] **Step 5: Run to verify pass**

Run: `bats extras/agent-sandboxing/tests/launch.bats`
Expected: all passing.

- [ ] **Step 6: Run full suite**

Run: `bats extras/agent-sandboxing/tests`
Expected: all passing.

- [ ] **Step 7: Commit**

```bash
git add extras/agent-sandboxing/lib/mysbx-core.zsh extras/agent-sandboxing/20-mysbx.zsh \
  extras/agent-sandboxing/tests/launch.bats
git commit -m "feat(mysbx): interactive all-in-one launch and aliases"
```

---

## Task 9: Stow wiring, remove dsbx, docs, manual verification

**Files:**
- Delete: `extras/agent-sandboxing/20-dsbx.zsh`
- Modify: `.claude/skills/agent-sandboxing/SKILL.md`
- Modify: `CLAUDE.md`
- Modify: `.stow-local-ignore` (only if it would capture `tests/` or `dot-local`)
- Verify: `install.sh`

- [ ] **Step 1: Confirm test dir + new dot-dirs are not stow-ignored**

Run: `cat .stow-local-ignore`
Check that `extras/` is already ignored (it is not stowed — it's sourced in place) and that `dot-local`/`dot-config` are stowable. If `.stow-local-ignore` lacks an `extras` rule, that's fine — verify by dry-run in Step 4. No edit unless the dry-run shows `tests/` or `lib/` being symlinked into `$HOME`.

- [ ] **Step 2: Delete the old dsbx file**

```bash
git rm extras/agent-sandboxing/20-dsbx.zsh
```
`init.zsh` globs `*.zsh`, so `20-mysbx.zsh` is picked up automatically and `20-dsbx.zsh` disappears. No init.zsh edit needed.

- [ ] **Step 3: Update the skill doc**

In `.claude/skills/agent-sandboxing/SKILL.md`, apply the rename and grammar change. Replace the `dsbx-*` table row and source path:
```
| `mysbx`  | [Docker `sbx`](https://docs.docker.com/ai/sandboxes/) | `dot-local/bin/mysbx` + `extras/agent-sandboxing/lib/mysbx-core.zsh` + `extras/agent-sandboxing/20-mysbx.zsh` + `extras/agent-sandboxing/templates/` |
```
And update the usage notes:
- Inner daemon socket var → `$_MYSBX_SBXD_SOCK`.
- Agent calls: `mysbx-omp -p "explain X"` (interactive function) still requires `--print`/`-p`.
- Sourcing for non-interactive use: `zsh -c 'source ~/dev/personal/dotfiles/extras/agent-sandboxing/init.zsh && mysbx-build omp-sandbox'`, OR simply call the executable: `mysbx build omp-sandbox`.
- `dsbx-build`→`mysbx build` (or `mysbx-build`); `dsbx-check`→`mysbx check`; recreate hint `<prefix> --recreate`→ `mysbx-cc --recreate` (interactive) / `mysbx create cc . --recreate` is **not** supported by the executable (faithful create errors on dup); use the interactive `mysbx-* --recreate`.
- Helper-mount section: `_dsbx_name`→`_mysbx_name`.

- [ ] **Step 4: Stow dry-run**

Run: `stow --dotfiles -n -v -t "$HOME" . 2>&1 | grep -E 'mysbx|local/bin|config/mysbx'`
Expected: shows `LINK: .local/bin/mysbx`, `LINK: .config/mysbx/config` (or a dir link). Confirm NO link for `extras/...` or `tests/`.

- [ ] **Step 5: Stow for real + verify on PATH**

```bash
./install.sh
which mysbx
mysbx version    # forwards to real sbx version (proves passthrough + resolution)
```
Expected: `~/.local/bin/mysbx` resolved; `mysbx version` prints sbx's version. (`~/.local/bin` must be on PATH — it is via existing dotfiles; if `which mysbx` is empty, that's a PATH issue to flag, not a mysbx bug.)

- [ ] **Step 6: Update CLAUDE.md note**

In `CLAUDE.md`, the Notes bullet referencing agent sandboxing:
```
- Agent sandboxing (`mysbx`, `mysbx-*`, `nono-*`, files under `extras/agent-sandboxing/` + `dot-local/bin/mysbx`): see the repo-scoped `agent-sandboxing` skill at `.claude/skills/agent-sandboxing/SKILL.md`.
```

- [ ] **Step 7: Full test suite + manual smoke**

```bash
bats extras/agent-sandboxing/tests
```
Expected: all passing.

Manual smoke (interactive shell, real sbx — run by the user, document results):
- `exec zsh` then `mysbx-omp -p "say hi"` → creates/reconnects, runs.
- `mysbx ls` → vanilla passthrough lists sandboxes.
- `mysbx create cc .` then `sbx ls` → sandbox `mysbx-cc-<cwd>` exists with kits.
- `mysbx check` → reports ok/stale for cwd sandboxes.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "chore(mysbx): wire stow, remove dsbx, update docs"
```

---

## Self-Review

**Spec coverage:**
- Faithful passthrough + verb dispatch → Task 1, 5, 6, 7. ✓
- Preset-as-agent augmentation (create/run) → Task 5. ✓
- Preset registry (agent/kits/template) → Task 2. ✓
- Secret sync hard-fail / directory-aware / stdin → Task 3. ✓
- Helper mounts → Task 4. ✓
- exec resync → Task 6. ✓
- All-in-one interactive-only → Task 8 (`_mysbx_launch` + functions; executable never create-if-needed). ✓
- `--clone` passthrough → Task 5. ✓
- Naming (derive vs explicit `--name`) → Task 2 (derive), Task 5 (`--name` honored). ✓
- Config + env override + real-sbx self-guard → Task 1. ✓
- Rename map + state/log/config dirs → Tasks 1-9. ✓
- Stow layout (`dot-local/bin`, `dot-config/mysbx`) → Task 1, 9. ✓
- bats with stub sbx → all tasks. ✓
- Docs (SKILL.md, CLAUDE.md) → Task 9. ✓
- No migration / delete dsbx → Task 9. ✓

**Placeholder scan:** No TBD/TODO. Heavy docker verbs (Task 7) are honestly scoped to dispatch-routing tests + manual verification, with full ported code shown.

**Type/name consistency:** `_mysbx_launch`, `_mysbx_augmented_create`, `_mysbx_sync_secrets`, `_mysbx_name`, `_mysbx_preset_{agent,template,kits}`, `_mysbx_is_preset`, `mysbx_dispatch`, `REAL_SBX`, `_MYSBX_STATE_DIR`, `_MYSBX_LOG` used consistently across tasks. Derived-name convention `mysbx-<preset>-<cwd>` matches between Task 5 (create) and Task 8 (launch) and the `mysbx-cc`/`mysbx-ruby-cc`/`mysbx-omp` prefixes in `_mysbx_update`/`_mysbx_check` (Task 7).

**Open implementation-time checks (from spec):** exact `sbx create` flag/positional ordering with `--clone`+kits+workspaces — verified in Task 9 manual smoke; the no-collision assumption (`cc`/`ruby-cc`/`omp` not real sbx agents) holds at design time.

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
    # Resolve both paths to their canonical forms (following symlinks).
    local d_resolved; d_resolved="$(cd "$d" 2>/dev/null && pwd -P)" || continue
    [[ "$cwd" == "$d_resolved"* ]] && continue
    mounts+=("$entry")
  done
  printf '%s\n' "${mounts[@]}"
}

# 0 (true) if expected mounts were provided and any is missing from the live
# sandbox; 1 if no expected mounts or all present.
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

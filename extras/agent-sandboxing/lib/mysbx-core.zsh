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

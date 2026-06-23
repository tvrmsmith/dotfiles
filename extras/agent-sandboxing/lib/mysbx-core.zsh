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

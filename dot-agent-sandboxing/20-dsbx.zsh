# Docker Sandbox (sbx) launchers and credential sync

_SBX_DIR="$DEV_PERSONAL/dotfiles/dot-claude/sandbox"
_DSBX_AUTH_DIR="$HOME/.cache/dsbx-auth"
_DSBX_LOG="$HOME/.cache/dsbx-auth/dsbx.log"
_DSBX_SECRET_TTL=3600  # 1 hour: skip GitHub secret resync if cached marker is fresher than this

# Sub-ms wall-clock without subprocess overhead.
zmodload zsh/datetime 2>/dev/null
_dsbx_now_ms() { printf '%.0f\n' $(( EPOCHREALTIME * 1000 )); }

# Profile a command's wall time. Logs to _DSBX_LOG; prints to stderr if _DSBX_PROFILE is set.
_dsbx_time() {
  local label="$1"; shift
  local start end elapsed
  start=$(_dsbx_now_ms)
  "$@"
  local rc=$?
  end=$(_dsbx_now_ms)
  elapsed=$(( end - start ))
  echo "$(date -Iseconds) [timing] ${label}=${elapsed}ms rc=${rc}" >> "$_DSBX_LOG"
  [ -n "$_DSBX_PROFILE" ] && echo "[dsbx] ${label}: ${elapsed}ms" >&2
  return $rc
}

# Resolve the GitHub identity for the current cwd.
# Personal: under $DEV_PERSONAL/ → personal account, per-sandbox scope.
# Work: everything else → work account, global scope.
# Echoes: "<op_account> <op_path> <scope_flag>" where scope_flag is `-g` or the sandbox name.
_dsbx_github_identity() {
  local sandbox_name="$1"
  case "$PWD/" in
    "$DEV_PERSONAL/"*)
      echo "my.1password.com $GIT_TOKEN_PERSONAL $sandbox_name"
      ;;
    *)
      echo "wellsky.1password.com $GIT_TOKEN -g"
      ;;
  esac
}

_dsbx_secret_marker() {
  local sandbox_name="$1"
  echo "$_DSBX_AUTH_DIR/${sandbox_name}.gh-secret"
}

_dsbx_secret_fresh() {
  local marker="$1"
  [ -f "$marker" ] || return 1
  local mtime age
  mtime=$(stat -f %m "$marker" 2>/dev/null) || return 1
  age=$(( $(date +%s) - mtime ))
  [ $age -lt $_DSBX_SECRET_TTL ]
}

# Sync the GitHub PAT for this sandbox from 1Password into sbx's proxy store.
# Idempotent and TTL-gated; safe to call before every dsbx-* invocation.
_dsbx_sync_github_secret() {
  local sandbox_name="$1"
  local marker; marker=$(_dsbx_secret_marker "$sandbox_name")
  if _dsbx_secret_fresh "$marker"; then
    return 0
  fi
  mkdir -p "$_DSBX_AUTH_DIR"

  local op_account op_path scope
  read -r op_account op_path scope <<< "$(_dsbx_github_identity "$sandbox_name")"

  local token
  if ! token=$(OP_ACCOUNT="$op_account" op read "$op_path" 2>>"$_DSBX_LOG"); then
    echo "[dsbx] failed to read GitHub PAT from 1Password ($op_account: $op_path)" >&2
    echo "[dsbx] is your op session active? try: eval \$(op signin --account $op_account)" >&2
    return 1
  fi

  # `set -f` overwrites without prompting; with stdin, the token never enters argv.
  local scope_arg
  if [ "$scope" = "-g" ]; then scope_arg="-g"; else scope_arg="$scope"; fi
  if ! printf '%s' "$token" | sbx secret set $scope_arg github -f >>"$_DSBX_LOG" 2>&1; then
    echo "[dsbx] failed to write GitHub secret to sbx (scope=$scope)" >&2
    return 1
  fi
  touch "$marker"
}

dsbx-build() {
  GITHUB_TOKEN="$(op read "$GIT_TOKEN")" \
  GITHUB_TOKEN_PERSONAL="$(OP_ACCOUNT=my.1password.com op read "$GIT_TOKEN_PERSONAL")" \
  GIT_USER_NAME="$(git config --global user.name)" \
  GIT_USER_EMAIL="$(git config --global user.email)" \
  DOTFILES_SHA="$(git -C "$DEV_PERSONAL/dotfiles" rev-parse HEAD)" \
  docker compose -f "$_SBX_DIR/docker-compose.yml" build "$@" && \
  for img in $(docker compose -f "$_SBX_DIR/docker-compose.yml" config --images); do
    echo "Loading $img into sbx..." && \
    docker save "$img" | sbx template load /dev/stdin
  done
}

_DSBX_HOST_ADC="$HOME/.config/gcloud/application_default_credentials.json"
_DSBX_HOST_PLUGIN_CACHE="$HOME/.claude/plugins/cache"

# Push host ADC into the sandbox at the canonical path. Idempotent.
# Re-syncs whenever host ADC mtime is newer than our marker (covers refresh).
_dsbx_sync_adc() {
  local name="$1"
  local marker="$_DSBX_AUTH_DIR/${name}.adc"
  if [ ! -f "$_DSBX_HOST_ADC" ]; then
    echo "[dsbx] no host ADC at $_DSBX_HOST_ADC; run: gcloud auth application-default login" >&2
    return 1
  fi
  if [ -f "$marker" ] && [ "$marker" -nt "$_DSBX_HOST_ADC" ]; then
    return 0
  fi
  mkdir -p "$_DSBX_AUTH_DIR"
  if ! sbx exec -i "$name" -- bash -c '
      install -d -m 700 "$HOME/.config/gcloud" &&
      umask 077 && cat > "$HOME/.config/gcloud/application_default_credentials.json"
    ' < "$_DSBX_HOST_ADC" 2>>"$_DSBX_LOG"; then
    echo "[dsbx] failed to copy ADC into $name" >&2
    return 1
  fi
  touch "$marker"
}

# Push host's Claude Code plugin cache into the sandbox at the canonical path.
# Idempotent. Re-syncs whenever any host cache file is newer than our marker.
# Empty/missing host cache is a silent no-op (not an error).
_dsbx_sync_plugin_cache() {
  local name="$1"
  local marker="$_DSBX_AUTH_DIR/${name}.plugin-cache"

  # Nothing to mirror — user hasn't populated CC plugins on the host. Not a failure.
  [ -d "$_DSBX_HOST_PLUGIN_CACHE" ] || return 0

  # Fast-exit when no host file is newer than the marker. -print -quit short-
  # circuits at the first match, so cache size doesn't dominate steady-state cost.
  if [ -f "$marker" ] \
     && [ -z "$(find "$_DSBX_HOST_PLUGIN_CACHE" -newer "$marker" -type f -print -quit 2>/dev/null)" ]; then
    return 0
  fi

  mkdir -p "$_DSBX_AUTH_DIR"

  if ! tar -C "$_DSBX_HOST_PLUGIN_CACHE" -cf - . \
      | sbx exec -i "$name" -- bash -c '
          install -d -m 755 "$HOME/.claude/plugins/cache" &&
          tar -C "$HOME/.claude/plugins/cache" -xf -
        ' 2>>"$_DSBX_LOG"; then
    echo "[dsbx] failed to copy claude plugin cache into $name" >&2
    return 1
  fi
  touch "$marker"
}

# Build sandbox name from prefix, cwd, and any extra workspaces.
_dsbx_name() {
  local prefix="$1"
  shift
  local name="${prefix}-$(basename "$(pwd)")"
  for ws in "$@"; do
    name="${name}--$(basename "${ws%:ro}")"
  done
  if _detect_git_worktree; then
    name="${name}--$(basename "$_GIT_WORKTREE_SOURCE_REPO")"
  fi
  echo "$name"
}

_DSBX_SBXD_SOCK="$HOME/Library/Application Support/com.docker.sandboxes/sandboxes/sandboxd/docker.sock"

# Remove orphan container/network in sbx's embedded containerd. sbx's own state
# can drift from containerd's after crashes; without this, recreate fails with
# `failed to create network: already exists`.
_dsbx_purge_orphans() {
  local name="$1"
  [ -S "$_DSBX_SBXD_SOCK" ] || return 0
  docker -H "unix://$_DSBX_SBXD_SOCK" rm -f "$name" >> "$_DSBX_LOG" 2>&1 || true
  docker -H "unix://$_DSBX_SBXD_SOCK" network rm "$name" >> "$_DSBX_LOG" 2>&1 || true
}

# Helper: create with template on first run, reconnect on subsequent runs.
# Auto-detects git worktrees and mounts the source repo for git access.
#
# Flags:
#   --recreate     Tear down an existing sandbox before creating a new one.
#   --print | -p   Skip the interactive `sbx run` attach; run `<print_cmd> -p <prompt>`
#                  via `sbx exec -i` instead. Remaining positional args form the prompt.
#                  Use this from inside another agent's bash tool: interactive attach
#                  grabs /dev/tty and on exit EPIPEs the parent's renderer.
_dsbx_run() {
  local template="$1" agent="$2" prefix="$3" print_cmd="$4"
  shift 4
  local recreate=0 print_mode=0
  local -a positional=()
  for arg in "$@"; do
    case "$arg" in
      --recreate)  recreate=1 ;;
      --print|-p)  print_mode=1 ;;
      *)           positional+=("$arg") ;;
    esac
  done
  # In interactive mode positional args are workspace mounts; in print mode they're prompt tokens.
  local -a extra_ws=() agent_args=()
  if (( print_mode )); then
    agent_args=("${positional[@]}")
  else
    extra_ws=("${positional[@]}")
  fi
  if _detect_git_worktree; then
    extra_ws+=("$_GIT_WORKTREE_SOURCE_REPO")
  fi
  local name
  name="$(_dsbx_name "$prefix" "${extra_ws[@]}")"
  if (( recreate )); then
    echo "$(date -Iseconds) Recreating $name" >> "$_DSBX_LOG"
    sbx rm -f "$name" >> "$_DSBX_LOG" 2>&1 || true
    _dsbx_purge_orphans "$name"
    rm -f "$_DSBX_AUTH_DIR/${name}.adc" \
          "$(_dsbx_secret_marker "$name")" \
          "$_DSBX_AUTH_DIR/${name}.plugin-cache"
  fi
  if ! sbx ls 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
    echo "$(date -Iseconds) Creating $name" >> "$_DSBX_LOG"
    if ! sbx create -t "$template" --name "$name" "$agent" . "${extra_ws[@]}" >> "$_DSBX_LOG" 2>&1; then
      echo "$(date -Iseconds) Create failed; purging orphans and retrying $name" >> "$_DSBX_LOG"
      _dsbx_purge_orphans "$name"
      sbx create -t "$template" --name "$name" "$agent" . "${extra_ws[@]}" >> "$_DSBX_LOG" 2>&1 || return 1
    fi
  fi
  _dsbx_time "sync-adc($name)" _dsbx_sync_adc "$name" || return 1
  _dsbx_time "sync-gh-secret($name)" _dsbx_sync_github_secret "$name" || return 1
  _dsbx_time "sync-plugin-cache($name)" _dsbx_sync_plugin_cache "$name" || return 1
  if (( print_mode )); then
    sbx exec -i "$name" -- "$print_cmd" -p "${agent_args[@]}"
    return $?
  fi
  sbx run "$name"
}

dsbx-cc()      { _dsbx_run claude-sandbox-mise:latest        claude dsbx-cc      claude "$@"; }
dsbx-ruby-cc() { _dsbx_run claude-sandbox-ruby-2.6.10:latest claude dsbx-ruby-cc claude "$@"; }
dsbx-omp()     { _dsbx_run omp-sandbox:latest                shell  dsbx-omp     omp    "$@"; }

_dsbx_exec() {
  local prefix="$1"
  shift
  local name
  name="$(_dsbx_name "$prefix")"
  sbx exec -it "$name" -- "$@"
}

dsbx-gauth() {
  local prefix="${1:-dsbx-omp}"
  local name
  name="$(_dsbx_name "$prefix")"
  gcloud auth application-default login || return 1
  _dsbx_sync_adc "$name"
}



# Check whether sandboxes for the current working directory are running on the
# latest built image. Inspects each existing sandbox's actual container image ID
# (via sbx's embedded daemon) and compares to the current outer docker image ID
# for that template. Sandboxes that don't exist for cwd are silently skipped.
# Exit non-zero if any existing cwd sandbox is stale.
dsbx-check() {
  local -a entries=(
    'dsbx-cc:claude-sandbox-mise:latest'
    'dsbx-ruby-cc:claude-sandbox-ruby-2.6.10:latest'
    'dsbx-omp:omp-sandbox:latest'
  )
  local rc=0 found=0
  local entry prefix img name container_id current_id
  for entry in "${entries[@]}"; do
    prefix="${entry%%:*}"
    img="${entry#*:}"
    name="$(_dsbx_name "$prefix")"
    if ! sbx ls 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
      continue
    fi
    found=1
    container_id=$(docker -H "unix://$_DSBX_SBXD_SOCK" inspect "$name" --format '{{.Image}}' 2>/dev/null \
      | sed 's/^sha256:\(.\{12\}\).*/\1/')
    current_id=$(docker image inspect --format '{{.Id}}' "$img" 2>/dev/null \
      | sed 's/^sha256:\(.\{12\}\).*/\1/')
    if [ -z "$current_id" ]; then
      printf 'missing-image    %s  (sandbox=%s; run dsbx-build)\n' "$img" "$name"
      rc=1
    elif [ -z "$container_id" ]; then
      printf 'unknown          %s  (could not inspect container; sbx daemon down?)\n' "$name"
      rc=1
    elif [ "$container_id" = "$current_id" ]; then
      printf 'ok               %s  %s  (%s)\n' "$name" "$container_id" "$img"
    else
      printf 'stale            %s  running=%s  current=%s  (recreate: %s --recreate)\n' \
        "$name" "$container_id" "$current_id" "$prefix"
      rc=1
    fi
  done
  if [ $found -eq 0 ]; then
    echo 'no sandboxes for this cwd'
  fi
  return $rc
}

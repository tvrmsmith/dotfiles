# Docker Sandbox (sbx) launchers and credential sync

_SBX_DIR="$_AGENT_SBX_ROOT/templates"
_DSBX_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dsbx"
_DSBX_LOG="$_DSBX_STATE_DIR/dsbx.log"
_DSBX_SECRET_TTL=3600  # 1 hour: skip secret resync if cached marker is fresher than this

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
# Echoes tab-delimited: "<op_account>\t<op_path>\t<scope_flag>"
_dsbx_github_identity() {
  local sandbox_name="$1"
  case "$PWD/" in
    "$DEV_PERSONAL/"*)
      printf '%s\t%s\t%s\n' "my.1password.com" "op://Private/GitHub Personal Access Token/token" "$sandbox_name"
      ;;
    *)
      printf '%s\t%s\t%s\n' "wellsky.1password.com" "$GIT_TOKEN" "-g"
      ;;
  esac
}

_dsbx_is_personal() { [[ "$PWD/" == "$DEV_PERSONAL/"* ]]; }

_dsbx_secret_marker() {
  local sandbox_name="$1" suffix="${2:-gh-secret}"
  echo "$_DSBX_STATE_DIR/markers/${sandbox_name}.${suffix}"
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
  mkdir -p "$_DSBX_STATE_DIR/markers"

  local op_account op_path scope
  IFS=$'\t' read -r op_account op_path scope <<< "$(_dsbx_github_identity "$sandbox_name")"

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

_dsbx_sync_atlassian_secret() {
  local sandbox_name="$1"
  local marker; marker=$(_dsbx_secret_marker "$sandbox_name" "atlassian-secret")
  if _dsbx_secret_fresh "$marker"; then
    return 0
  fi
  mkdir -p "$_DSBX_STATE_DIR/markers"

  local token
  if ! token=$(OP_ACCOUNT="wellsky.1password.com" op read "op://Employee/JIRA CLI Token/credential" 2>>"$_DSBX_LOG"); then
    echo "[dsbx] failed to read Atlassian token from 1Password" >&2
    echo "[dsbx] is your op session active? try: eval \$(op signin --account wellsky.1password.com)" >&2
    return 1
  fi

  local b64
  b64=$(printf '%s:%s' "$JIRA_USERNAME" "$token" | base64)
  if ! printf '%s' "$b64" | sbx secret set -g atlassian -f >>"$_DSBX_LOG" 2>&1; then
    echo "[dsbx] failed to write Atlassian secret to sbx" >&2
    return 1
  fi
  touch "$marker"
}

dsbx-build() {
  docker compose -f "$_SBX_DIR/docker-compose.yml" build "$@" && \
  for img in $(docker compose -f "$_SBX_DIR/docker-compose.yml" config --images); do
    echo "Loading $img into sbx..." && \
    docker save "$img" | sbx template load /dev/stdin
  done || return

  # Auto-chain personal omp fork build when omp-sandbox was (re)built and the
  # fork worktree exists. No args = built everything, so omp-sandbox is in.
  if [ -d "$_DSBX_OMP_FORK_HOST_DIR" ] && { [ $# -eq 0 ] || (( ${@[(I)omp-sandbox]} )); }; then
    echo "[dsbx-build] chaining dsbx-omp-build" >&2
    dsbx-omp-build
  fi
}

# Helper bind mounts. Workspaces appended to `sbx create` but excluded from
# the sandbox name (so they don't bloat sandbox identity). Mounted read-only at
# their host paths inside the container; we then symlink the canonical lookup
# locations to those mount paths so unmodified tools (gcloud SDK, omp's plugin
# discovery) find what they expect.
_DSBX_HELPER_ADC_DIR="$HOME/.config/gcloud"
_DSBX_HELPER_PLUGINS_DIR="$HOME/.claude/plugins"
_DSBX_HELPER_DOTFILES_DIR="$DEV_PERSONAL/dotfiles"
# Personal omp fork: source of truth (RO), and built tree (RO into sandboxes).
# Build is host-side via `dsbx-omp-build`; sandboxes mount the built tree.
_DSBX_OMP_FORK_HOST_DIR="$DEV_PERSONAL/oh-my-pi-personal-build"
_DSBX_OMP_FORK_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dsbx/omp-fork"
_DSBX_OMP_FORK_BUN_VOLUME="dsbx-omp-fork-buncache"
_DSBX_OMP_FORK_CARGO_VOLUME="dsbx-omp-fork-cargocache"

# Helper bind mounts. Workspaces appended to `sbx create` but excluded from
# the sandbox name (so they don't bloat sandbox identity). Candidates carry
# their own access-mode suffix: `:ro` for read-only, bare path for read-write.
# Entries whose host path is missing are silently skipped.
_dsbx_helper_mounts() {
  local sandbox_state="$1"
  local -a mounts=()
  local cwd; cwd="$(pwd -P)"
  local -a candidates=(
    "${_DSBX_HELPER_ADC_DIR}:ro"
    "${_DSBX_HELPER_PLUGINS_DIR}:ro"
    "${_DSBX_HELPER_DOTFILES_DIR}:ro"
    "${_DSBX_OMP_FORK_CACHE_DIR}:ro"
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


# Returns 0 (true) if the existing sandbox is missing any of the helper mounts
# we currently expect. Used to auto-recreate sandboxes that predate a change to
# the helper-mount set (e.g. adding gcloud ADC), since bind mounts can only be
# attached at `sbx create` time.
_dsbx_helper_mounts_stale() {
  local name="$1"; shift
  local -a expected=("$@")
  (( ${#expected[@]} )) || return 1
  local actual
  actual=$(sbx ls --json 2>/dev/null \
    | jq -r --arg n "$name" '.sandboxes[] | select(.name==$n) | .workspaces[]') || return 1
  local m
  for m in "${expected[@]}"; do
    grep -qxF -- "$m" <<< "$actual" || return 0
  done
  return 1
}

# Kit paths
_DSBX_KITS_TOOLING="$_AGENT_SBX_ROOT/kits/tooling"
_DSBX_KITS_CLAUDE_PATCH="$_AGENT_SBX_ROOT/kits/claude-code-patch"
_DSBX_KITS_PERSONAL="$_AGENT_SBX_ROOT/kits/personal"
_DSBX_KITS_ATLASSIAN="$_AGENT_SBX_ROOT/kits/atlassian"
_DSBX_KITS_OMP="$_AGENT_SBX_ROOT/kits/omp"

# Build the personal-build oh-my-pi worktree on the host into a cache dir that
# every dsbx-omp sandbox bind-mounts RO. Replaces the per-sandbox sbx-cp + bun
# install + cargo build cycle: one host build, N sandboxes share it live, no
# --recreate needed when the fork changes (the bind mount is a live view).
#
# Layout:
#   $_DSBX_OMP_FORK_HOST_DIR  RO source (your fork worktree)
#   $_DSBX_OMP_FORK_CACHE_DIR  RW build output (rsynced source + node_modules + native .node)
#   $_DSBX_OMP_FORK_BUN_VOLUME    docker named volume for bun download cache
#   $_DSBX_OMP_FORK_CARGO_VOLUME  docker named volume for cargo registry+git+target
#
# Bun + cargo download caches live in named volumes (not bind mounts) — they're
# only used during the build container's life and don't need to be visible to
# sandboxes or the host.
#
# Idempotent and incremental: rsync only copies changed source, bun install
# reuses node_modules, cargo reuses target/. Cold first run takes minutes
# (rust nightly compile); warm reruns are seconds.
dsbx-omp-build() {
  if [ ! -d "$_DSBX_OMP_FORK_HOST_DIR" ]; then
    echo "[dsbx-omp-build] fork worktree missing: $_DSBX_OMP_FORK_HOST_DIR" >&2
    return 1
  fi
  if ! docker image inspect omp-sandbox:latest >/dev/null 2>&1; then
    echo "[dsbx-omp-build] omp-sandbox:latest not built; run dsbx-build omp-sandbox first" >&2
    return 1
  fi
  mkdir -p "$_DSBX_OMP_FORK_CACHE_DIR"
  docker volume inspect "$_DSBX_OMP_FORK_BUN_VOLUME" >/dev/null 2>&1 || \
    docker volume create "$_DSBX_OMP_FORK_BUN_VOLUME" >/dev/null
  docker volume inspect "$_DSBX_OMP_FORK_CARGO_VOLUME" >/dev/null 2>&1 || \
    docker volume create "$_DSBX_OMP_FORK_CARGO_VOLUME" >/dev/null

  local host_hash=""
  if command -v git >/dev/null 2>&1; then
    host_hash=$(git -C "$_DSBX_OMP_FORK_HOST_DIR" rev-parse HEAD 2>/dev/null || true)
  fi
  echo "[dsbx-omp-build] building $_DSBX_OMP_FORK_HOST_DIR ${host_hash:+@ $host_hash} -> $_DSBX_OMP_FORK_CACHE_DIR" >&2
  docker run --rm \
    -v "$_DSBX_OMP_FORK_HOST_DIR:/src:ro" \
    -v "$_DSBX_OMP_FORK_CACHE_DIR:/out" \
    -v "$_DSBX_OMP_FORK_BUN_VOLUME:/root/.bun/install/cache" \
    -v "$_DSBX_OMP_FORK_CARGO_VOLUME:/usr/local/cargo-cache" \
    -e CARGO_HOME=/usr/local/cargo-cache \
    -e CARGO_TARGET_DIR=/usr/local/cargo-cache/target \
    -e HOST_HASH="$host_hash" \
    --user 0:0 \
    omp-sandbox:latest bash -c '\
      set -euo pipefail; \
      # rsync source into /out, excluding ephemera and host-built artifacts that
      # would clash with linux-arm64 (darwin .node, host node_modules, .git, etc).
      rsync -a --delete \
        --exclude=.git --exclude=node_modules --exclude=target \
        --exclude="packages/natives/native/*.node" \
        /src/ /out/; \
      cd /out; \
      echo "[dsbx-omp-build] bun install" >&2; \
      bun install --frozen-lockfile || bun install; \
      echo "[dsbx-omp-build] cargo build linux-arm64 native" >&2; \
      bun run --cwd packages/natives build; \
      # Stamp the host HEAD hash for diagnostics. Computed on the host because
      # /src is RO and may have permission/owner mismatches that confuse git.
      printf "%s\n" "$HOST_HASH" > /out/.dsbx-fork-hash; \
      echo "[dsbx-omp-build] ready @ ${HOST_HASH:-unknown}" >&2; \
    '
}

# Wipe the build cache. Bun + cargo named volumes are kept by default (cold
# rebuild from those is still fast); pass --all to nuke everything.
dsbx-omp-clean() {
  rm -rf "$_DSBX_OMP_FORK_CACHE_DIR"
  if [ "${1:-}" = --all ]; then
    docker volume rm -f "$_DSBX_OMP_FORK_BUN_VOLUME" "$_DSBX_OMP_FORK_CARGO_VOLUME" >/dev/null 2>&1 || true
  fi
  echo "[dsbx-omp-clean] removed $_DSBX_OMP_FORK_CACHE_DIR${1:+ + named volumes}" >&2
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
# Args:
#   template (empty string if agent kit provides it), agent, prefix, print_cmd,
#   kit_paths... -- [user_args...]
#
# Kit paths are listed before `--`; user args (--recreate, --print, workspaces)
# follow after `--`.
#
# Flags (in user args):
#   --recreate     Tear down an existing sandbox before creating a new one.
#   --print | -p   Skip the interactive `sbx run` attach; run `<print_cmd> -p <prompt>`
#                  via `sbx exec -i` instead. Remaining positional args form the prompt.
_dsbx_run() {
  local template="$1" agent="$2" prefix="$3" print_cmd="$4"
  shift 4

  local -a kits=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    kits+=("$1"); shift
  done
  [[ "${1:-}" == "--" ]] && shift

  local recreate=0 print_mode=0
  local -a positional=()
  for arg in "$@"; do
    case "$arg" in
      --recreate)  recreate=1 ;;
      --print|-p)  print_mode=1 ;;
      *)           positional+=("$arg") ;;
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
  local name
  name="$(_dsbx_name "$prefix" "${extra_ws[@]}")"
  local sandbox_state_dir="$_DSBX_STATE_DIR/sandboxes/$name"
  mkdir -p "$sandbox_state_dir"/{sessions,plans,projects}
  [ -f "$sandbox_state_dir/history.jsonl" ] || touch "$sandbox_state_dir/history.jsonl"
  local -a helper_mounts=()
  helper_mounts=(${(f)"$(_dsbx_helper_mounts "$sandbox_state_dir")"})
  if ! (( recreate )) && sbx ls 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
    if _dsbx_helper_mounts_stale "$name" "${helper_mounts[@]}"; then
      echo "$(date -Iseconds) Helper mounts stale on $name, auto-recreating" >> "$_DSBX_LOG"
      recreate=1
    fi
  fi
  if (( recreate )); then
    echo "$(date -Iseconds) Recreating $name" >> "$_DSBX_LOG"
    sbx rm -f "$name" >> "$_DSBX_LOG" 2>&1 || true
    _dsbx_purge_orphans "$name"
    rm -f "$_DSBX_STATE_DIR/markers/${name}".{gh,atlassian}-secret
  fi
  if ! sbx ls 2>/dev/null | awk '{print $1}' | grep -qx "$name"; then
    echo "$(date -Iseconds) Creating $name" >> "$_DSBX_LOG"
    local -a kit_args=()
    for k in "${kits[@]}"; do
      kit_args+=(--kit "$k")
    done
    local -a tmpl_args=()
    [[ -n "$template" ]] && tmpl_args=(-t "$template")
    if ! sbx create "${tmpl_args[@]}" --name "$name" "${kit_args[@]}" \
        "$agent" . "${extra_ws[@]}" "${helper_mounts[@]}" 2> >(tee -a "$_DSBX_LOG" >&2) >> "$_DSBX_LOG"; then
      echo "$(date -Iseconds) Create failed; purging orphans and retrying $name" >> "$_DSBX_LOG"
      _dsbx_purge_orphans "$name"
      if ! sbx create "${tmpl_args[@]}" --name "$name" "${kit_args[@]}" \
          "$agent" . "${extra_ws[@]}" "${helper_mounts[@]}" 2> >(tee -a "$_DSBX_LOG" >&2) >> "$_DSBX_LOG"; then
        echo "[dsbx] sbx create failed for $name (see $_DSBX_LOG)" >&2
        return 1
      fi
    fi
  fi
  _dsbx_time "sync-gh-secret($name)" _dsbx_sync_github_secret "$name" || return 1
  if ! _dsbx_is_personal; then
    _dsbx_time "sync-atlassian-secret($name)" _dsbx_sync_atlassian_secret "$name" || return 1
  fi
  if (( print_mode )); then
    sbx exec -i "$name" -- "$print_cmd" -p "${agent_args[@]}"
    return $?
  fi
  sbx run "$name"
}

dsbx-cc() {
  local -a kits=("$_DSBX_KITS_TOOLING" "$_DSBX_KITS_CLAUDE_PATCH" "$_DSBX_KITS_PERSONAL")
  _dsbx_is_personal || kits+=("$_DSBX_KITS_ATLASSIAN")
  _dsbx_run "" claude dsbx-cc claude "${kits[@]}" -- "$@"
}
dsbx-ruby-cc() {
  local -a kits=("$_DSBX_KITS_TOOLING" "$_DSBX_KITS_CLAUDE_PATCH" "$_DSBX_KITS_PERSONAL")
  _dsbx_is_personal || kits+=("$_DSBX_KITS_ATLASSIAN")
  _dsbx_run claude-sandbox-ruby-2.6.10:latest claude dsbx-ruby-cc claude "${kits[@]}" -- "$@"
}
dsbx-omp() {
  local -a kits=("$_DSBX_KITS_PERSONAL")
  _dsbx_is_personal || kits+=("$_DSBX_KITS_ATLASSIAN")
  kits+=("$_DSBX_KITS_OMP")
  _dsbx_run "" omp dsbx-omp omp "${kits[@]}" -- "$@"
}

_dsbx_exec() {
  local prefix="$1"
  shift
  local name
  name="$(_dsbx_name "$prefix")"
  sbx exec -it "$name" -- "$@"
}

# Re-apply a kit to a running sandbox (e.g. to update tools).
dsbx-update() {
  local -a prefixes=(dsbx-cc dsbx-ruby-cc dsbx-omp)
  local -a kits=("$_DSBX_KITS_TOOLING" "$_DSBX_KITS_CLAUDE_PATCH" "$_DSBX_KITS_PERSONAL")
  _dsbx_is_personal || kits+=("$_DSBX_KITS_ATLASSIAN")
  local found=0
  for prefix in "${prefixes[@]}"; do
    local name
    name="$(_dsbx_name "$prefix")"
    sbx ls 2>/dev/null | awk '{print $1}' | grep -qx "$name" || continue
    found=1
    for kit in "${kits[@]}"; do
      echo "[dsbx] applying $(basename "$kit") to $name" >&2
      sbx kit add "$name" "$kit"
    done
  done
  if (( ! found )); then
    echo "[dsbx] no sandboxes found for this directory" >&2
    return 1
  fi
}

# Check whether sandboxes for the current working directory are running on the
# latest built image. Inspects each existing sandbox's actual container image ID
# (via sbx's embedded daemon) and compares to the current outer docker image ID
# for that template. Sandboxes that don't exist for cwd are silently skipped.
# Exit non-zero if any existing cwd sandbox is stale.
dsbx-check() {
  local -a entries=(
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

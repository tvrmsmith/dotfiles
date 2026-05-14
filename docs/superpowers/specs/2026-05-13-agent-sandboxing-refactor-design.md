# Agent Sandboxing Refactor: Kits + Consolidation

**Date:** 2026-05-13
**Status:** Draft

## Summary

Refactor agent sandboxing scripts to:
1. Consolidate all sandboxing files (scripts, Dockerfiles, kits) under `extras/agent-sandboxing/`
2. Adopt Docker sandbox kits for credentials, static files, and post-create setup
3. Replace stow-based sourcing with direct `init.zsh` sourcing from repo path
4. Eliminate `install-helper-links.sh` — all setup moves into a kit-owned `install.sh`

## Decisions

- **Approach A (consolidate in dotfiles)** chosen over repo split. Sandboxing is deeply personal (1Password accounts, omp fork, Vertex projects). Kit system provides domain separation within one repo.
- **Template + kit layering** for all agents. Custom Dockerfiles (templates) handle heavy toolchain installs. Kits layer credentials, static files, and runtime setup on top.
- **Kit files for static configs, bind mounts for live host state.** `.gitconfig.sandbox` and `known_hosts.pinned` go into kit `files/`. gcloud ADC, claude plugins, omp fork cache stay as bind mounts (need live host updates). Full dotfiles repo stow inside sandboxes continues as-is.
- **OMP kit is `kind: agent`** — defines image + entrypoint. CC sandboxes use mixin kits only.
- **Atlassian credentials via proxy** — `JIRA_API_TOKEN` proxy-managed, `JIRA_USERNAME` and `JIRA_BASE_URL` set to placeholders so ws-atlassian skill sees them as configured.
- **GitHub PAT flow unchanged** — keep current `op read` + `sbx secret set` TTL-gated sync.
- **nono stack stays** — kept alongside dsbx, no changes.

## New Directory Structure

```
extras/agent-sandboxing/              # was dot-agent-sandboxing/ + dot-claude/sandbox/
├── init.zsh                          # NEW: single entry point sourced from .zshrc
├── 00-shared.zsh                     # moved from dot-agent-sandboxing/
├── 10-nono.zsh                       # moved from dot-agent-sandboxing/
├── 20-dsbx.zsh                       # moved from dot-agent-sandboxing/ (modified)
├── templates/                        # moved from dot-claude/sandbox/
│   ├── docker-compose.yml
│   ├── Dockerfile.claude-sandbox.mise
│   ├── Dockerfile.claude-sandbox.ruby-2.6.10
│   └── Dockerfile.omp-sandbox
└── kits/
    ├── personal/                     # mixin: static configs + install.sh
    │   ├── spec.yaml
    │   └── files/
    │       └── home/
    │           ├── .gitconfig.sandbox
    │           ├── .ssh/
    │           │   └── known_hosts.pinned
    │           └── install.sh
    ├── atlassian/                    # mixin: proxy-managed Jira/Confluence creds
    │   └── spec.yaml
    └── omp/                          # agent: OMP image + entrypoint + Vertex env
        └── spec.yaml
```

### Deleted paths

- `dot-agent-sandboxing/` — moved to `extras/agent-sandboxing/`
- `dot-claude/sandbox/` — moved to `extras/agent-sandboxing/templates/`
- `dot-agent-sandboxing/install-helper-links.sh` — replaced by `kits/personal/files/home/install.sh`
- `dot-claude/sandbox/setup-signing-key.sh` — legacy, already unused

## Sourcing Strategy

### `extras/agent-sandboxing/init.zsh`

```zsh
_AGENT_SBX_ROOT="${0:A:h}"
for _f in "$_AGENT_SBX_ROOT"/*.zsh; do
  [[ "${_f:t}" == init.zsh ]] && continue
  source "$_f"
done; unset _f
```

Sets `_AGENT_SBX_ROOT` to the resolved directory of init.zsh. All scripts use this for relative path access to `templates/` and `kits/`.

### `.zshrc` change (line 128)

```zsh
# Before:
[ -d ~/.agent-sandboxing ] && for _f in ~/.agent-sandboxing/*.zsh; do source "$_f"; done; unset _f

# After:
[ -f "$DEV_PERSONAL/dotfiles/extras/agent-sandboxing/init.zsh" ] && \
  source "$DEV_PERSONAL/dotfiles/extras/agent-sandboxing/init.zsh"
```

No stow involvement — `extras/` is already in `.stow-local-ignore`.

## Kit Specifications

### Kit 1: `personal` (mixin)

Applied to every sandbox (CC and OMP). Places static configs via `files/` and runs `install.sh` for bind-mount symlinks, dotfiles stow, and SSH known_hosts merge.

```yaml
schemaVersion: "1"
kind: mixin
name: personal
displayName: Personal Dotfiles
description: Static personal configs and bind-mount symlink setup

commands:
  install:
    - command: "bash /home/agent/install.sh"
      user: "1000"
      description: Set up bind-mount symlinks, stow dotfiles, merge SSH known_hosts
```

#### `files/home/.gitconfig.sandbox`

```ini
[gpg "ssh"]
	program = /usr/bin/ssh-keygen
	allowedSignersFile = /home/agent/.ssh/allowed_signers
```

#### `files/home/.ssh/known_hosts.pinned`

Copied from current `dot-ssh/known_hosts.pinned`.

#### `files/home/install.sh`

Replaces `install-helper-links.sh`. All operations conditional on bind mount existence.

```bash
#!/usr/bin/env bash
set -euo pipefail

: "${HOST_HOME:?HOST_HOME required}"
: "${DEV_PERSONAL:?DEV_PERSONAL required}"

# 1. gcloud ADC symlink
if [ -d "$HOST_HOME/.config/gcloud" ]; then
  install -d -m 700 "$HOME/.config/gcloud"
  ln -sf "$HOST_HOME/.config/gcloud/application_default_credentials.json" \
    "$HOME/.config/gcloud/application_default_credentials.json"
fi

# 2. Claude plugins symlink
if [ -d "$HOST_HOME/.claude/plugins" ]; then
  rm -rf "$HOME/.claude/plugins"
  ln -sfn "$HOST_HOME/.claude/plugins" "$HOME/.claude/plugins"
fi

# 3. omp fork symlink (dangling if no host build — launcher shim handles fallback)
ln -sfn "$HOST_HOME/.cache/dsbx-omp-fork" "$HOME/.omp-fork"

# 4. stow host dotfiles
DOTFILES_MOUNT="$DEV_PERSONAL/dotfiles"
if [ -d "$DOTFILES_MOUNT" ]; then
  cd "$DOTFILES_MOUNT"
  rm -f "$HOME/.bashrc" "$HOME/.gitconfig" "$HOME/.claude/settings.json"

  ignore_args=(--ignore=extras)
  while IFS= read -r abs; do
    ignore_args+=(--ignore="$(basename "$abs")")
  done < <(find . -type l ! -path "./.git/*" -exec sh -c \
    'tgt=$(readlink "$1"); case "$tgt" in /*) echo "$1";; esac' _ {} \;)

  stow --no-folding --dotfiles -t "$HOME" "${ignore_args[@]}" .
fi

# 5. SSH known_hosts merge (kit places known_hosts.pinned, we merge it)
if [ -f "$HOME/.ssh/known_hosts.pinned" ]; then
  install -d -m 700 "$HOME/.ssh"
  cat "$HOME/.ssh/known_hosts.pinned" >> "$HOME/.ssh/known_hosts"
  sort -u "$HOME/.ssh/known_hosts" -o "$HOME/.ssh/known_hosts"
  chmod 644 "$HOME/.ssh/known_hosts"
fi
```

**Note:** `HOST_HOME` and `DEV_PERSONAL` must be passed as env vars to the kit install command. This is handled by updating `_dsbx_run` to set these via `sbx create` environment or by the kit's `environment.variables` section.

### Kit 2: `atlassian` (mixin)

Applied to every sandbox. Provides proxy-managed Jira/Confluence access.

```yaml
schemaVersion: "1"
kind: mixin
name: atlassian
displayName: Atlassian Access
description: Proxy-managed Jira and Confluence credentials

network:
  allowedDomains:
    - "*.atlassian.net"
  serviceDomains:
    "wellsky.atlassian.net": atlassian
  serviceAuth:
    atlassian:
      headerName: Authorization
      valueFormat: "Basic %s"

credentials:
  sources:
    atlassian:
      env:
        - JIRA_API_TOKEN
      priority: env-first

environment:
  variables:
    JIRA_USERNAME: "proxy-managed"
    JIRA_BASE_URL: "https://wellsky.atlassian.net"
  proxyManaged:
    - JIRA_API_TOKEN
```

### Kit 3: `omp` (agent kit)

Defines OMP as a complete agent. References the `omp-sandbox:latest` template image.

```yaml
schemaVersion: "1"
kind: agent
name: omp
displayName: Oh My Pi Agent
description: OMP coding agent with Vertex AI

agent:
  image: "omp-sandbox:latest"
  entrypoint:
    run: ["/usr/local/bin/claude"]

environment:
  variables:
    GOOGLE_CLOUD_PROJECT: "${GOOGLE_CLOUD_PROJECT}"
    GOOGLE_CLOUD_LOCATION: "${GOOGLE_CLOUD_LOCATION}"
    OMP_MODEL: "${OMP_MODEL}"
```

## Changes to `20-dsbx.zsh`

### Path updates

| Old | New |
|-----|-----|
| `_SBX_DIR="$DEV_PERSONAL/dotfiles/dot-claude/sandbox"` | `_SBX_DIR="$_AGENT_SBX_ROOT/templates"` |
| `install-helper-links.sh` path | deleted — kit handles it |

### Deleted functions

- `_dsbx_install_helper_links()` — replaced by kit install command

### Modified `_dsbx_run`

Key changes:
1. Accept kit list as parameter (varies per launcher)
2. Pass `--kit` flags to `sbx create`
3. Remove `created` flag and `_dsbx_install_helper_links` call
4. Pass `HOST_HOME` and `DEV_PERSONAL` env vars via `-e` on `sbx create`

```zsh
_dsbx_run() {
  local template="$1" agent="$2" prefix="$3" print_cmd="$4"
  shift 4

  # Parse kit list (terminated by --)
  local -a kits=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do
    kits+=("$1"); shift
  done
  [[ "${1:-}" == "--" ]] && shift

  # ... (rest of existing flag parsing: --recreate, --print, positional args)

  # Build --kit args
  local -a kit_args=()
  for k in "${kits[@]}"; do
    kit_args+=(--kit "$k")
  done

  # sbx create with kits (install.sh runs automatically via kit)
  sbx create -t "$template" --name "$name" \
    "${kit_args[@]}" \
    -e HOST_HOME="$HOME" -e DEV_PERSONAL="$DEV_PERSONAL" \
    "$agent" . "${extra_ws[@]}" "${helper_mounts[@]}"

  # No _dsbx_install_helper_links call — kit install handles it
  # ...
}
```

### Updated launchers

```zsh
_DSBX_KITS_PERSONAL="$_AGENT_SBX_ROOT/kits/personal"
_DSBX_KITS_ATLASSIAN="$_AGENT_SBX_ROOT/kits/atlassian"
_DSBX_KITS_OMP="$_AGENT_SBX_ROOT/kits/omp"

dsbx-cc() {
  _dsbx_run claude-sandbox-mise:latest claude dsbx-cc claude \
    "$_DSBX_KITS_PERSONAL" "$_DSBX_KITS_ATLASSIAN" -- "$@"
}

dsbx-ruby-cc() {
  _dsbx_run claude-sandbox-ruby-2.6.10:latest claude dsbx-ruby-cc claude \
    "$_DSBX_KITS_PERSONAL" "$_DSBX_KITS_ATLASSIAN" -- "$@"
}

dsbx-omp() {
  # No -t template flag — OMP agent kit defines the image via agent.image
  _dsbx_run "" claude dsbx-omp omp \
    "$_DSBX_KITS_PERSONAL" "$_DSBX_KITS_ATLASSIAN" "$_DSBX_KITS_OMP" -- "$@"
}
```

### `dsbx-build` update

```zsh
dsbx-build() {
  docker compose -f "$_SBX_DIR/docker-compose.yml" build "$@" && \
  for img in $(docker compose -f "$_SBX_DIR/docker-compose.yml" config --images); do
    echo "Loading $img into sbx..." && \
    docker save "$img" | sbx template load /dev/stdin
  done || return
  # ... (omp-build chain unchanged)
}
```

## Dockerfile Changes

### Removals from Dockerfiles

Both `Dockerfile.claude-sandbox.mise` and `Dockerfile.omp-sandbox` currently bake `.gitconfig.sandbox` into the image:

```dockerfile
RUN printf '%s\n' \
    '[gpg "ssh"]' \
    '	program = /usr/bin/ssh-keygen' \
    '	allowedSignersFile = /home/agent/.ssh/allowed_signers' \
    > /home/agent/.gitconfig.sandbox && \
  chown agent:agent /home/agent/.gitconfig.sandbox
```

This gets **removed** from both Dockerfiles — the personal kit `files/home/.gitconfig.sandbox` handles it now.

### `Dockerfile.claude-sandbox.ruby-2.6.10`

Remove `COPY . /home/agent/.claude` (line 102) — this copied the entire `dot-claude/sandbox/` directory into the image, which is no longer relevant since Dockerfiles moved to `templates/`.

## Stow Changes

### `.stow-local-ignore`

Add `dot-agent-sandboxing` to ignore list (directory no longer stowed):

```
^/dot-agent-sandboxing
```

Wait — `dot-agent-sandboxing/` is being **moved** to `extras/agent-sandboxing/`, so it won't exist. No `.stow-local-ignore` change needed for it. `extras/` is already ignored.

### What stops being stowed

- `dot-agent-sandboxing/` no longer exists → nothing to stow
- `~/.agent-sandboxing/` symlink tree goes away
- Users must `rm -rf ~/.agent-sandboxing` after migration (one-time cleanup)

## Skill Update

`.claude/skills/agent-sandboxing/SKILL.md` needs path updates:

| Old reference | New reference |
|---------------|---------------|
| `dot-agent-sandboxing/` | `extras/agent-sandboxing/` |
| `dot-claude/sandbox/` | `extras/agent-sandboxing/templates/` |
| `dot-agent-sandboxing/20-dsbx.zsh` | `extras/agent-sandboxing/20-dsbx.zsh` |

## Migration Steps (for the user)

1. Run `stow -D --dotfiles -t "$HOME" .` to unstow current dotfiles
2. Move files to new locations
3. Re-stow: `stow --dotfiles -t "$HOME" .`
4. Remove stale symlink tree: `rm -rf ~/.agent-sandboxing`
5. Recreate all sandboxes: `dsbx-cc --recreate`, `dsbx-omp --recreate`
6. Source new shell config: `exec zsh`

## Implementation Risks (validate during implementation)

1. **`HOST_HOME` and `DEV_PERSONAL` env var injection** — kit `commands.install` needs these for bind-mount symlinks. Pass via `sbx create -e` (host-specific values, not suited for committed kit spec). Validate that `-e` vars are visible to kit install commands.

2. **Kit env var substitution** — the OMP kit uses `${GOOGLE_CLOUD_PROJECT}` etc. Validate that sbx substitutes host env vars in `spec.yaml` at create time. Fallback: pass via `sbx create -e` instead.

3. **`sbx create` without `-t` when agent kit is used** — OMP launcher passes no template flag; the agent kit's `agent.image` field provides it. Validate this works. If sbx requires `-t` even with agent kits, pass `-t omp-sandbox:latest` redundantly.

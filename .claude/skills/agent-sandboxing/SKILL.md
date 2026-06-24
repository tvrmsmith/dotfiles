---
name: agent-sandboxing
description: Use when working with agent sandboxes in this dotfiles repo (`mysbx`, `mysbx-*`, `nono-*` aliases, files under `extras/agent-sandboxing/`), invoking sandbox helpers from an agent's bash tool, or rebuilding sandbox images. Triggers on: mysbx, mysbx-omp, mysbx-cc, mysbx-build, sbx, nono, sandbox, omp-sandbox, claude-sandbox.
---

# Agent Sandboxing (this repo)

Two stacks. Edit the source files directly — don't duplicate aliases elsewhere.

| Stack    | Backend                                               | Source                                                                              |
| -------- | ----------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `nono-*` | [nsjail](https://nono.sh/docs/)                       | `extras/agent-sandboxing/10-nono.zsh`                                                  |
| `mysbx`  | [Docker `sbx`](https://docs.docker.com/ai/sandboxes/) | `dot-local/bin/mysbx` + `extras/agent-sandboxing/lib/mysbx-core.zsh` + `extras/agent-sandboxing/20-mysbx.zsh` + `extras/agent-sandboxing/templates/` |

Shared helpers: `extras/agent-sandboxing/00-shared.zsh`. Sourced via `extras/agent-sandboxing/init.zsh` from `.zshrc`.

Kits: `extras/agent-sandboxing/kits/` — personal (static configs + install.sh), atlassian (proxy-managed creds), omp (agent kit).

## `sbx` runs in an embedded containerd

Host `docker ps`/`exec`/`logs` won't see sandbox containers.

- Normal ops: `sbx ls` / `sbx exec` / `sbx run` / `sbx rm`
- Inner daemon (orphan cleanup, debugging): `docker -H unix://$_MYSBX_SBXD_SOCK ...`

## Calling from an agent's bash tool

**Always pass `--print` / `-p`** to `mysbx-*` interactive commands:

```bash
mysbx-omp -p "explain X"
```

Without it, `sbx run` grabs `/dev/tty` and EPIPEs the parent's renderer on exit, wedging the host terminal.

**Never spawn an interactive shell** (`zsh -i`, `bash -i`, `exec zsh`, `$SHELL -i`) — same TTY-grab failure mode.

`mysbx-*` functions are sourced only by the interactive rc. The `mysbx` executable is on PATH and safe to call directly from a bash tool. For non-interactive use, either call the executable or source the init file:

```bash
zsh -c 'source ~/dev/personal/dotfiles/extras/agent-sandboxing/init.zsh && mysbx-build omp-sandbox'
```

Or simply call the executable:

```bash
mysbx build omp-sandbox
```

## Rebuilding sandbox images

`mysbx build` (or the interactive `mysbx-build`) is the one entry point. It:

1. Reads `GIT_TOKEN` (work) and `GIT_TOKEN_PERSONAL` (personal) via `op read` — auths through 1Password desktop on demand, no `op signin` needed
2. Runs `docker compose -f extras/agent-sandboxing/templates/docker-compose.yml build "$@"`
3. `docker save | sbx template load` per built image

Args = compose service names (`claude-sandbox-mise`, `claude-sandbox-ruby-2-6-10`, `omp-sandbox`); omit to build all.

**Build order matters:** `claude-sandbox-ruby-2-6-10` depends on `claude-sandbox-mise:latest`. Build mise first: `mysbx build claude-sandbox-mise && mysbx build claude-sandbox-ruby-2-6-10 omp-sandbox`.

When invoking from a bash tool:

- **Slow.** Cold build ~5 min (ruby-2.6.10 compiles from source). Set `timeout` ≥ 1800.
- **Output exceeds 50KB and gets truncated.** Success markers: `Image <name> Built` and `Loading <name> into sbx... Load complete.`
- **`omp-sandbox` needs `~/dev/personal/omp-extension-anthropic-vertex`** (declared as `additional_contexts`). Build fails if missing.
- **Expected non-fatal noise:** dotfiles `install.sh` can't clone SSH-only nvim submodules (`Host key verification failed`); trailing `compose config --images` env warnings (`GIT_USER_NAME ... is not set`) are post-build and harmless.

`sbx template load` only updates the template — existing sandboxes keep the old image. Use `mysbx check` to spot stale ones; use the interactive `mysbx-cc --recreate` or `mysbx-omp --recreate` to refresh (the executable `mysbx create` does not support `--recreate`).

## Helper bind mounts (gcloud ADC, Claude plugins)

Mounted read-only into every `mysbx` sandbox at create time, at the same path inside the container as on the host:

| Host path           | Why                                                       |
| ------------------- | --------------------------------------------------------- |
| `~/.config/gcloud`  | gcloud SDK / Application Default Credentials              |
| `~/.claude/plugins` | Claude plugin registry + cache (omp and cc both consume) |

The personal kit's `install.sh` (runs via kit `commands.startup` — `startup` runs after `files/` are copied and workspaces mounted; `install` runs before both) symlinks canonical lookup paths to the mounts:

- `~/.config/gcloud/application_default_credentials.json` → bind mount
- `~/.claude/plugins` → bind mount

Updates on the host propagate instantly. Helper mounts are excluded from `_mysbx_name` so they don't bloat sandbox identity.

Re-run `gcloud auth application-default login` on the host for fresh ADC — there is no `mysbx-gauth`. Sandboxes predating this layout need `--recreate` once to pick up the mounts.

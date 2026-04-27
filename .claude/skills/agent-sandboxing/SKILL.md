---
name: agent-sandboxing
description: Use when working with agent sandboxes in this dotfiles repo (`dsbx-*`, `nono-*` aliases, files under `dot-agent-sandboxing/` or `dot-claude/sandbox/`), invoking sandbox helpers from an agent's bash tool, or rebuilding sandbox images. Triggers on: dsbx, dsbx-omp, dsbx-cc, dsbx-build, sbx, nono, sandbox, omp-sandbox, claude-sandbox.
---

# Agent Sandboxing (this repo)

Two stacks. Edit the source files directly — don't duplicate aliases elsewhere.

| Stack    | Backend                                               | Source                                                                              |
| -------- | ----------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `nono-*` | [nsjail](https://nono.sh/docs/)                       | `dot-agent-sandboxing/10-nono.zsh`                                                  |
| `dsbx-*` | [Docker `sbx`](https://docs.docker.com/ai/sandboxes/) | `dot-agent-sandboxing/20-dsbx.zsh` + `dot-claude/sandbox/` (Dockerfiles + compose) |

Shared helpers: `dot-agent-sandboxing/00-shared.zsh`. The whole dir is glob-sourced by the shell rc.

## `sbx` runs in an embedded containerd

Host `docker ps`/`exec`/`logs` won't see sandbox containers.

- Normal ops: `sbx ls` / `sbx exec` / `sbx run` / `sbx rm`
- Inner daemon (orphan cleanup, debugging): `docker -H unix://$_DSBX_SBXD_SOCK ...`

## Calling from an agent's bash tool

**Always pass `--print` / `-p`** to `dsbx-*` agent commands:

```bash
dsbx-omp -p "explain X"
```

Without it, `sbx run` grabs `/dev/tty` and EPIPEs the parent's renderer on exit, wedging the host terminal.

**Never spawn an interactive shell** (`zsh -i`, `bash -i`, `exec zsh`, `$SHELL -i`) — same TTY-grab failure mode.

`dsbx-*` are **functions** sourced only by the interactive rc. Plain `zsh -c 'dsbx-build'` won't see them. Source the file first:

```bash
zsh -c 'source ~/dev/personal/dotfiles/dot-agent-sandboxing/20-dsbx.zsh && dsbx-build omp-sandbox'
```

## Rebuilding sandbox images

`dsbx-build` is the one entry point. It:

1. Reads `GIT_TOKEN` (work) and `GIT_TOKEN_PERSONAL` (personal) via `op read` — auths through 1Password desktop on demand, no `op signin` needed
2. Runs `docker compose -f dot-claude/sandbox/docker-compose.yml build "$@"`
3. `docker save | sbx template load` per built image

Args = compose service names (`claude-sandbox-mise`, `claude-sandbox-ruby-2.6.10`, `omp-sandbox`); omit to build all.

When invoking from a bash tool:

- **Slow.** Cold build ~5 min (ruby-2.6.10 compiles from source). Set `timeout` ≥ 1800.
- **Output exceeds 50KB and gets truncated.** Success markers: `Image <name> Built` and `Loading <name> into sbx... Load complete.`
- **`omp-sandbox` needs `~/dev/personal/omp-extension-anthropic-vertex`** (declared as `additional_contexts`). Build fails if missing.
- **Expected non-fatal noise:** dotfiles `install.sh` can't clone SSH-only nvim submodules (`Host key verification failed`); trailing `compose config --images` env warnings (`GIT_USER_NAME ... is not set`) are post-build and harmless.

`sbx template load` only updates the template — existing sandboxes keep the old image. Use `dsbx-check` to spot stale ones; `<prefix> --recreate` to refresh.

## Helper bind mounts (gcloud ADC, Claude plugins)

Mounted read-only into every `dsbx-*` at create time, at the same path inside the container as on the host:

| Host path           | Why                                                       |
| ------------------- | --------------------------------------------------------- |
| `~/.config/gcloud`  | gcloud SDK / Application Default Credentials              |
| `~/.claude/plugins` | Claude plugin registry + cache (omp and cc both consume) |

`_dsbx_install_helper_links` (post-create, idempotent) symlinks canonical lookup paths to the mounts:

- `~/.config/gcloud/application_default_credentials.json` → bind mount
- `~/.claude/plugins` → bind mount

Updates on the host propagate instantly. Helper mounts are excluded from `_dsbx_name` so they don't bloat sandbox identity.

Re-run `gcloud auth application-default login` on the host for fresh ADC — there is no `dsbx-gauth`. Sandboxes predating this layout need `--recreate` once to pick up the mounts.

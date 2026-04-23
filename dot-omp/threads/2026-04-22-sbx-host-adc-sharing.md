# Sharing host gcloud ADC with Docker sandboxes (sbx)

**Date:** 2026-04-22
**Repo:** `~/dev/personal/dotfiles`
**Files referenced:** `dot-agent-sandboxing`, `dot-claude/sandbox/Dockerfile.{omp-sandbox,claude-sandbox.mise}`, `dot-claude/sandbox/docker-compose.yml`

## Question

Is there a way to share the host machine's Google Application Default Credentials (ADC) with Docker sandboxes (https://docs.docker.com/ai/sandboxes/), given multiple `dsbx-*` aliases in `dot-agent-sandboxing`?

## Background

`dot-agent-sandboxing` defines `nono-*` (nsjail) and `dsbx-*` (Docker sandbox) flavors of agent launchers. The current dsbx flow handles GCP auth by running an interactive `gcloud auth application-default login --no-launch-browser` *inside* each sandbox, gated by a 6h TTL marker file in `~/.cache/dsbx-auth/`. Every new sandbox needs its own login.

## Why it's awkward

`sbx secret` only supports a fixed service list (anthropic, openai, github, aws, google-gemini, etc.) — gcloud ADC isn't in it. There's no `--volume` flag on `sbx run`/`sbx create`, and the docs explicitly warn against symlinks to host paths. So "just bind-mount `~/.config/gcloud`" isn't an option the way it would be with plain `docker run`.

Per https://docs.docker.com/ai/sandboxes/security/credentials/ and the FAQ, the supported escape hatch for non-supported credentials is `/etc/sandbox-persistent.sh` (env vars only), or extra workspaces (read-only mounts at create time).

## Two viable options

### (A) Mount `~/.config/gcloud` as a read-only extra workspace

```bash
sbx run claude ~/project ~/.config/gcloud:ro
```

Extra workspaces appear inside the sandbox at their **absolute host paths** — so the file lands at `/Users/trevor.smith/.config/gcloud/application_default_credentials.json`. gcloud's well-known lookup is `$HOME/.config/gcloud/...` inside the sandbox (i.e. `/home/agent/.config/gcloud/...`), so this also requires setting `GOOGLE_APPLICATION_CREDENTIALS` to point at the host path. Workable but leaks the macOS host path into the sandbox name (your `_dsbx_name` suffix logic already handles `:ro`), and forces an env-var override.

### (B) Stream the host ADC into the sandbox via `sbx exec` after create [recommended]

ADC is just a refresh-token JSON. The same file works inside the sandbox because oauth2.googleapis.com is reachable (the existing in-sandbox `gcloud auth application-default login` flow proves it). One `sbx exec ... bash -c 'cat > …' < host_adc` writes it to the canonical `~/.config/gcloud/application_default_credentials.json` — no env-var override, no host paths leaked.

Either way, **ADC** is the right unit to share. Short-lived access tokens (`print-access-token`) expire in ~1 h and can't be refreshed inside the sandbox without the refresh token anyway.

## Patch sketch for `dot-agent-sandboxing`

```bash
# Path to host ADC
_DSBX_HOST_ADC="$HOME/.config/gcloud/application_default_credentials.json"

# Push host ADC into the sandbox at the canonical path. Idempotent.
# Re-runs whenever the host ADC mtime is newer than the in-sandbox copy marker
# (covers token-refresh on the host).
_dsbx_sync_adc() {
  local name="$1"
  local marker="$_DSBX_AUTH_DIR/${name}.adc"
  [ -f "$_DSBX_HOST_ADC" ] || {
    echo "[dsbx] no host ADC at $_DSBX_HOST_ADC; run: gcloud auth application-default login" >&2
    return 1
  }
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
```

In `_dsbx_run`, replace the `_dsbx_needs_auth` / in-sandbox `gcloud auth application-default login` block with:

```bash
_dsbx_time "sync-adc($name)" _dsbx_sync_adc "$name" || return 1
_dsbx_time "sync-gh-secret($name)" _dsbx_sync_github_secret "$name" || return 1
```

`dsbx-gauth` becomes a host-side refresh + push:

```bash
dsbx-gauth() {
  local prefix="${1:-dsbx-omp}"
  local name; name="$(_dsbx_name "$prefix")"
  gcloud auth application-default login --no-launch-browser || return 1
  _dsbx_sync_adc "$name"
}
```

You can also drop `_DSBX_ADC_TTL`, `_dsbx_needs_auth`, and `_dsbx_mark_authed` — the host-ADC mtime check subsumes them, and there's no longer a meaningful "in-sandbox auth state" to track.

## Caveats flagged

1. **Quota project**: ADC alone doesn't carry the gcloud quota project. If in-sandbox calls hit `quota project not set`, set `GOOGLE_CLOUD_QUOTA_PROJECT` in the sandbox env (or run `gcloud auth application-default set-quota-project $ANTHROPIC_VERTEX_PROJECT_ID` inside once after first sync).
2. **Trust scope**: the sandbox now holds the refresh token — same blast radius as the personal `nono` profile (which already does `--override-deny ~/.config/gcloud`). Consistent, not worse.
3. **No per-sandbox GCP identity**: every `dsbx-*` shares the same host ADC. Nothing in the current setup needs per-sandbox GCP identities.

## `install` command (clarification)

`install` is coreutils — combines `cp` + `mkdir` + `chmod` + `chown` atomically. In `install -d -m 700 "$HOME/.config/gcloud"`:

- `-d` → directory mode (like `mkdir -p`)
- `-m 700` → set mode at creation, atomically (vs `mkdir` then `chmod`, which leaves a window with `0777 & ~umask`)

Idempotent: if the directory already exists, `install -d` is a no-op for content and **does not** re-chmod by default — matches the desired "ensure exists with these perms, don't fight existing state" semantic.

The corresponding file write uses `umask 077 && cat > …` — same role for the file itself (created `0600`, never wider).

## Does the host ADC redirection work for `sbx exec`?

Honest answer: not verified from the conversation environment. Public sbx docs don't explicitly document stdin behavior for `sbx exec`. Two pieces of indirect evidence it works:

1. The existing script already pipes into `sbx secret set`:
   `printf '%s' "$token" | sbx secret set $scope_arg github -f`
   That's host stdin → sbx subprocess → daemon → sandbox-side process, working in current code.
2. The Docker docs FAQ uses `sbx exec -d <name> bash -c "echo ... >> /etc/..."` — same shape (redirect-inside-`bash -c`).

### Important fix from the original patch sketch

`sbx exec "$name" -- bash -c '...' < "$_DSBX_HOST_ADC"` with **no `-i`** is wrong. By Docker convention stdin only attaches with `-i`, and `-t` would corrupt the JSON via terminal CR↔LF translation. Correct form:

```bash
sbx exec -i "$name" -- bash -c '
    install -d -m 700 "$HOME/.config/gcloud" &&
    umask 077 && cat > "$HOME/.config/gcloud/application_default_credentials.json"
  ' < "$_DSBX_HOST_ADC"
```

Verify the file landed intact:

```bash
sbx exec "$name" -- sha256sum "$HOME/.config/gcloud/application_default_credentials.json"
shasum -a 256 "$_DSBX_HOST_ADC"
```

### Fallbacks if `sbx exec` doesn't pipe stdin like docker does

**Embed content in the command (no stdin):**

```bash
local b64; b64=$(base64 < "$_DSBX_HOST_ADC")
sbx exec "$name" -- bash -c '
    install -d -m 700 "$HOME/.config/gcloud" &&
    umask 077 &&
    printf %s "'"$b64"'" | base64 -d > "$HOME/.config/gcloud/application_default_credentials.json"
  '
```

Token is briefly in `sbx exec` argv on the host — same trust model as `op read` output already in the script. base64 hop avoids quoting/newline issues with the JSON itself.

**Mount + copy (sidesteps stdin entirely):**

```bash
sbx create -t "$template" --name "$name" "$agent" . "$HOME/.config/gcloud:ro" "${extra_ws[@]}"
sbx exec "$name" -- bash -c '
    install -d -m 700 "$HOME/.config/gcloud" &&
    install -m 600 "'"$HOME"'/.config/gcloud/application_default_credentials.json" \
      "$HOME/.config/gcloud/application_default_credentials.json"
  '
```

Cost: macOS host path leaks into sandbox name (your `_dsbx_name` already handles `:ro` mounts in the suffix). Extra workspaces are only set at create time, so ADC refreshes after sandbox creation aren't picked up automatically — would need a re-copy step on subsequent runs anyway.

## Recommendation

Apply the patch with `-i` added, then verify with the `sha256sum` check. If it works → cleanest code. If `sbx exec` turns out not to plumb stdin → switch to the base64 fallback. The mount-and-copy variant only wins if sandbox-side users need to refresh ADC themselves (not the case here).

## References

- Docker Sandboxes credentials: https://docs.docker.com/ai/sandboxes/security/credentials/
- Docker Sandboxes FAQ (custom env vars, `/etc/sandbox-persistent.sh`): https://docs.docker.com/ai/sandboxes/faq/
- Docker Sandboxes usage (extra workspaces, branch mode): https://docs.docker.com/ai/sandboxes/usage/
- `sbx exec` reference: https://docs.docker.com/reference/cli/sbx/exec/
- `sbx secret set` reference: https://docs.docker.com/reference/cli/sbx/secret/set/
- sbx releases (v0.25.0 highlights): https://github.com/docker/sbx-releases/releases/tag/v0.25.0

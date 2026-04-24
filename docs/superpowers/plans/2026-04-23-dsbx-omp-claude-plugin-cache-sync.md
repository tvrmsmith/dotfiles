# dsbx-omp Claude Plugin Cache Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Mirror the host's `~/.claude/plugins/cache/` into the sandbox before `sbx run`, so the omp `claude-skills-bridge` extension can resolve enabled marketplace plugins.

**Architecture:** Add one peer helper `_dsbx_sync_plugin_cache` next to `_dsbx_sync_adc` in `dot-agent-sandboxing`. It uses an mtime-newer-than-marker freshness check, tar-pipes the host cache through `sbx exec -i`, and is invoked unconditionally from `_dsbx_run` alongside the existing adc/gh-secret syncs. Marker is cleared on `--recreate` for symmetry with the other markers.

**Tech Stack:** zsh/bash, `sbx exec`, `tar`, `find`. Single-file change to `dot-agent-sandboxing` (a sourced shell file).

---

## File Structure

- **Modify:** `~/dotfiles/dot-agent-sandboxing` (~5 hunks; ~25 net new lines)
  - Add constant `_DSBX_HOST_PLUGIN_CACHE` near `_DSBX_HOST_ADC` (~line 146)
  - Add helper `_dsbx_sync_plugin_cache` directly after `_dsbx_sync_adc` (after line 169)
  - Add `rm -f` of plugin-cache marker inside `--recreate` block (line 222)
  - Add `_dsbx_time "sync-plugin-cache(...)" _dsbx_sync_plugin_cache "$name"` call inside `_dsbx_run` after the gh-secret sync (after line 233)

- **No new files.** No new tests file (this is shell glue verified through end-to-end behavior; manual verification steps included).

Reference (read-only):
- `~/dotfiles/dot-pi/agent/extensions/claude-skills-bridge.ts` — the consumer
- `~/dotfiles/dot-claude/settings.json` — the source of truth for enabled plugins
- `~/dotfiles/docs/superpowers/specs/2026-04-23-dsbx-omp-claude-plugin-cache-sync-design.md` — spec

---

## Task 1: Add host-cache constant

**Files:**
- Modify: `~/dotfiles/dot-agent-sandboxing` (insert after the existing `_DSBX_HOST_ADC` line, near line 146)

- [ ] **Step 1: Read the surrounding section to confirm anchor**

Run: `read ~/dotfiles/dot-agent-sandboxing` selecting lines `L144-L170`.
Confirm `_DSBX_HOST_ADC="$HOME/.config/gcloud/application_default_credentials.json"` is the last constant before the `# Push host ADC into the sandbox at the canonical path. Idempotent.` comment.

- [ ] **Step 2: Add the constant**

Insert this single line directly after the `_DSBX_HOST_ADC=...` line:

```sh
_DSBX_HOST_PLUGIN_CACHE="$HOME/.claude/plugins/cache"
```

- [ ] **Step 3: Sanity-check the file still sources cleanly**

Run: `zsh -n ~/dotfiles/dot-agent-sandboxing && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git -C ~/dotfiles add dot-agent-sandboxing
git -C ~/dotfiles commit -m "dsbx: add _DSBX_HOST_PLUGIN_CACHE constant"
```

---

## Task 2: Add `_dsbx_sync_plugin_cache` helper

**Files:**
- Modify: `~/dotfiles/dot-agent-sandboxing` (insert directly after the closing `}` of `_dsbx_sync_adc`, currently at line 169)

- [ ] **Step 1: Re-read the file to get fresh anchors after Task 1's edit**

Run: `read ~/dotfiles/dot-agent-sandboxing` selecting `L145-L185`.
Confirm `_dsbx_sync_adc()` ends with `}` and the next block is `# Build sandbox name from prefix, cwd, and any extra workspaces.`

- [ ] **Step 2: Insert the helper**

Insert these lines between the closing `}` of `_dsbx_sync_adc` and the `# Build sandbox name ...` comment:

```sh

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
```

- [ ] **Step 3: Sanity-check the file still parses**

Run: `zsh -n ~/dotfiles/dot-agent-sandboxing && echo OK`
Expected: `OK`

- [ ] **Step 4: Source the file in a fresh shell and confirm the function exists**

Run: `zsh -c 'source ~/dotfiles/dot-agent-sandboxing && type _dsbx_sync_plugin_cache'`
Expected: output starts with `_dsbx_sync_plugin_cache is a shell function`

- [ ] **Step 5: Commit**

```bash
git -C ~/dotfiles add dot-agent-sandboxing
git -C ~/dotfiles commit -m "dsbx: add _dsbx_sync_plugin_cache helper"
```

---

## Task 3: Wire helper into `_dsbx_run`

**Files:**
- Modify: `~/dotfiles/dot-agent-sandboxing` (insert one line after the gh-secret sync, originally line 233)

- [ ] **Step 1: Re-read fresh anchors around the sync block**

Run: `read ~/dotfiles/dot-agent-sandboxing` selecting `L228-L240`.
Confirm the two existing sync calls are present:
```
_dsbx_time "sync-adc($name)" _dsbx_sync_adc "$name" || return 1
_dsbx_time "sync-gh-secret($name)" _dsbx_sync_github_secret "$name" || return 1
sbx run "$name"
```

- [ ] **Step 2: Insert the new sync call between the gh-secret sync and `sbx run`**

After the `_dsbx_sync_github_secret` line, insert:

```sh
  _dsbx_time "sync-plugin-cache($name)" _dsbx_sync_plugin_cache "$name" || return 1
```

(Two-space indent matches the surrounding function body.)

- [ ] **Step 3: Sanity-check parse**

Run: `zsh -n ~/dotfiles/dot-agent-sandboxing && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git -C ~/dotfiles add dot-agent-sandboxing
git -C ~/dotfiles commit -m "dsbx: invoke plugin-cache sync from _dsbx_run"
```

---

## Task 4: Clear the new marker on `--recreate`

**Files:**
- Modify: `~/dotfiles/dot-agent-sandboxing` (the `rm -f` line inside the `if (( recreate )); then` block, originally line 222)

- [ ] **Step 1: Re-read fresh anchors for the recreate block**

Run: `read ~/dotfiles/dot-agent-sandboxing` selecting `L218-L226`.
Confirm the existing line:
```
    rm -f "$_DSBX_AUTH_DIR/${name}.adc" "$(_dsbx_secret_marker "$name")"
```

- [ ] **Step 2: Replace that line to also clear the plugin-cache marker**

Replace the single line above with:

```sh
    rm -f "$_DSBX_AUTH_DIR/${name}.adc" \
          "$(_dsbx_secret_marker "$name")" \
          "$_DSBX_AUTH_DIR/${name}.plugin-cache"
```

- [ ] **Step 3: Sanity-check parse**

Run: `zsh -n ~/dotfiles/dot-agent-sandboxing && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git -C ~/dotfiles add dot-agent-sandboxing
git -C ~/dotfiles commit -m "dsbx: clear plugin-cache marker on --recreate"
```

---

## Task 5: Verify in a live `dsbx-omp` sandbox

This is verification only — no code edits. Each step is observable behavior, not a passing test.

- [ ] **Step 1: Confirm host cache is populated**

Run: `ls ~/.claude/plugins/cache | head`
Expected: at least one marketplace directory (e.g., `claude-plugins-official`, `wellsky-plugins`).
If empty, run Claude Code on host once to populate, then re-check.

- [ ] **Step 2: Recreate the sandbox to start from a clean state**

From a directory you normally use `dsbx-omp` in (e.g., `~/dev/personal/dotfiles`):

```bash
dsbx-omp --recreate
```

Inside the omp session, exit immediately (`/quit` or Ctrl-D). The sandbox keeps running.

- [ ] **Step 3: Inspect the sandbox's cache directory**

```bash
sbx exec -it "$(_dsbx_name dsbx-omp)" -- ls ~/.claude/plugins/cache
```

(Or use `sbx ls` to find the sandbox name and run `sbx exec -it <name> -- ls ~/.claude/plugins/cache`.)

Expected: same marketplace directories as on host.

- [ ] **Step 4: Confirm bridge sees skills**

Re-enter the sandbox (`dsbx-omp`) and inside the omp REPL list available skills. Expected: skills from at least one enabled marketplace plugin (e.g., one of `claude-plugins-official`, `wellsky-plugins`, `caveman`, `hashicorp`).

If none appear, check `_DSBX_LOG` (`~/.cache/dsbx-auth/dsbx.log`) for `sync-plugin-cache(...)` timing entries and any tar errors.

- [ ] **Step 5: Confirm fast-exit on no-change**

Exit omp. Re-run `dsbx-omp` (no `--recreate`). Then:

```bash
tail -n 5 ~/.cache/dsbx-auth/dsbx.log | grep sync-plugin-cache
```

Expected: the most recent `sync-plugin-cache(...)` entry has a small `=Nms` value (single-digit or low-double-digit ms — only `find` ran, no tar).

- [ ] **Step 6: Confirm re-sync on host change**

```bash
touch ~/.claude/plugins/cache  # bump mtime of any file under it; or `find ~/.claude/plugins/cache -type f -print -quit | xargs touch`
```

Actually do this in a way that touches a *file* under the cache (since the helper greps with `-type f`):

```bash
find ~/.claude/plugins/cache -type f -print -quit | xargs touch
```

Run `dsbx-omp`, exit. Then:

```bash
tail -n 5 ~/.cache/dsbx-auth/dsbx.log | grep sync-plugin-cache
```

Expected: timing is noticeably larger than Step 5 (tar ran).

- [ ] **Step 7: Confirm `--recreate` re-seeds even when host cache is unchanged**

Without touching host cache:

```bash
dsbx-omp --recreate
```

Exit. Then:

```bash
sbx exec -it "$(_dsbx_name dsbx-omp)" -- ls ~/.claude/plugins/cache
```

Expected: cache populated. Confirms the marker was cleared so the helper didn't short-circuit into an empty sandbox.

- [ ] **Step 8: Confirm `dsbx-cc` still works**

```bash
dsbx-cc
```

Expected: launches normally; `_DSBX_LOG` shows a `sync-plugin-cache(dsbx-cc-...)` line that either succeeds or short-circuits. No regression.

- [ ] **Step 9: No commit (verification-only task)**

If verification fails, file findings as a follow-up task; do not silently fix in this plan.

---

## Self-Review

**Spec coverage** (each spec section → task):

| Spec section | Covered by |
|---|---|
| New helper `_dsbx_sync_plugin_cache` | Task 1 (constant) + Task 2 (helper body) |
| Wiring in `_dsbx_run` (unconditional, all callers) | Task 3 |
| `--recreate` clears the marker | Task 4 |
| Empty host cache → silent no-op | Task 2 step 2, `[ -d ... ] || return 0` |
| `find -newer` short-circuit | Task 2 step 2; verified Task 5 step 5 |
| Tar pipe via `sbx exec -i` | Task 2 step 2 |
| `dsbx-build` / `dsbx-check` unchanged | Implicit (no task) — confirmed in spec, not a deliverable |
| End-to-end success | Task 5 step 4 |

No spec sections without tasks.

**Placeholder scan:** none. All code blocks complete; all commands have expected outputs.

**Type/name consistency:**
- `_DSBX_HOST_PLUGIN_CACHE` defined in Task 1, referenced by name in Task 2 ✓
- `_dsbx_sync_plugin_cache` defined in Task 2, called by name in Task 3 ✓
- Marker path `$_DSBX_AUTH_DIR/${name}.plugin-cache` identical in Task 2 (set), Task 4 (cleared on recreate), Task 5 step 5 (observed via log) ✓
- Indentation in Task 3 (two spaces) matches sibling lines in `_dsbx_run` per source inspection ✓

No fixes needed.

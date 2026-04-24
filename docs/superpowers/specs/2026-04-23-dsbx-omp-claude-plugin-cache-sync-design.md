---
date: 2026-04-23
topic: dsbx-omp Claude plugin cache sync
status: draft
---

# `dsbx-omp` Claude plugin cache sync

## Problem

Inside `dsbx-omp`, the `claude-skills-bridge` pi extension reads
`~/.claude/settings.json` (`enabledPlugins` + `extraKnownMarketplaces`) and walks
`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/` to register
plugin-supplied skills with omp.

The settings file gets into the sandbox via dotfiles install. The cache directory
does not. Claude Code populates that cache when CC runs; the omp-sandbox image
has no Claude Code, so the cache stays empty and the bridge finds nothing — even
though the host has a fully-populated cache from running CC there.

`dsbx-cc` doesn't need this because Claude Code populates the cache on first run
inside the sandbox.

## Goal

Before `sbx run` for `dsbx-omp`, mirror the host's
`~/.claude/plugins/cache/` into the sandbox at the same path so the bridge can
resolve enabled plugins. Match the existing `_dsbx_sync_adc` /
`_dsbx_sync_github_secret` convention: idempotent, mtime-gated, host-marker
driven, cleared on `--recreate`.

## Non-goals

- Reimplementing CC's marketplace install pipeline inside the sandbox.
- Driving `claude -p` inside the sandbox to fetch plugins (rejected — adds CC as
  an omp-sandbox dependency, requires extra image bytes, and the user already
  maintains the host cache for their host CC workflow).
- Bind-mounting the host cache into the sandbox (writes from inside would
  corrupt host state).
- Generalizing the sync helpers into a shared abstraction. Today there are two
  syncs (adc, gh-secret) plus this one (cache). The marker-pattern boilerplate
  is ~5 lines per peer; the per-sync logic (file vs tree, copy mechanics,
  freshness check) differs enough that an abstraction would either need awkward
  bash callbacks or a leaky `--tree` flag. Revisit if a fourth peer arrives.
- Syncing into `dsbx-cc` or `dsbx-ruby-cc`. Those run Claude Code itself, which
  manages its own cache.

## Design

### New helper: `_dsbx_sync_plugin_cache`

Lives in `dot-agent-sandboxing` next to `_dsbx_sync_adc`. Same shape:

```sh
_DSBX_HOST_PLUGIN_CACHE="$HOME/.claude/plugins/cache"

_dsbx_sync_plugin_cache() {
  local name="$1"
  local marker="$_DSBX_AUTH_DIR/${name}.plugin-cache"

  [ -d "$_DSBX_HOST_PLUGIN_CACHE" ] || return 0  # nothing to sync; not an error

  # Skip if marker exists and no host file is newer than it
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

Notes:

- **Empty host cache → silent no-op (return 0).** A user without a populated
  host cache (e.g., never ran CC, or just ran `rm -rf ~/.claude/plugins/cache`)
  is not a failure mode — there's just nothing to mirror. Matches the
  permissiveness of optional sync.
- **Freshness check uses `-newer`.** `find ... -newer marker -type f -print -quit`
  short-circuits at the first newer file, so even a deep cache with thousands of
  files exits in milliseconds when the cache is unchanged.
- **Mirror the whole tree.** Filtering by `enabledPlugins` would reimplement
  settings parsing in shell; the bridge already filters by `enabledPlugins` at
  read time. Extra bytes are skill/agent text files, not binaries — small.
- **Tar pipe over `sbx exec -i`** matches the `_dsbx_sync_adc` mechanism and
  avoids a host-side bind mount (which would let sandbox writes corrupt host
  state).
- **No `--delete` semantics.** Adds files but never removes them. If a plugin
  is removed from host cache, the stale copy stays in the sandbox until
  `--recreate`. Acceptable: the bridge filters by `enabledPlugins` at runtime,
  so a stale on-disk plugin that's no longer enabled won't surface skills. A
  removed-but-still-enabled plugin would show stale skills, but that's a
  user-visible config inconsistency on the host that they'd notice.

### Wiring in `_dsbx_run`

Add one line beside the existing sync calls:

```sh
_dsbx_time "sync-adc($name)"           _dsbx_sync_adc            "$name" || return 1
_dsbx_time "sync-gh-secret($name)"     _dsbx_sync_github_secret  "$name" || return 1
_dsbx_time "sync-plugin-cache($name)"  _dsbx_sync_plugin_cache   "$name" || return 1
sbx run "$name"
```

Order doesn't matter — the three syncs are independent — but listing
plugin-cache last keeps adc/gh-secret (which other agents may also need)
visually grouped.

### Scope: `dsbx-omp` only, or all `_dsbx_run` callers?

`_dsbx_run` is shared by `dsbx-cc`, `dsbx-ruby-cc`, and `dsbx-omp`. The cache
sync is only meaningful for omp (CC manages its own cache; ruby-cc inherits the
mise sandbox image which does have CC). Two options:

1. **Add unconditionally in `_dsbx_run`.** Cheap, no-op for sandboxes whose
   bridge doesn't read the cache. Costs: one `find` per run on cc/ruby-cc
   sandboxes for a path their CC will overwrite anyway. Symmetric with
   `_dsbx_sync_adc`, which also runs unconditionally.
2. **Add only in `dsbx-omp` wrapper.** Surgical. Costs: special-cases omp;
   future agents that also need the cache would need to opt in.

Pick **option 1**. The find is cheap (cache changes infrequently → marker stays
fresh → fast-exit), and the sync is harmless on sandboxes that don't read the
cache. CC inside `dsbx-cc` may overwrite seeded files on its own startup, but
that's the same content from the same host source — net zero. Matches the
"sync everything any sandbox might want" posture of `_dsbx_sync_adc`.

### `--recreate` interaction

User's note: `--recreate` produces a fresh sandbox image (`sbx rm` + recreate
from template). The sandbox-side cache dir is empty after recreate.

The plugin-cache marker is host-side. If the host cache hasn't changed since
the previous successful sync, `find -newer` returns empty and the helper
short-circuits — leaving the new sandbox empty.

Therefore the marker MUST be cleared on `--recreate`, the same way
`${name}.adc` and the gh-secret marker already are:

```sh
if (( recreate )); then
  ...
  rm -f "$_DSBX_AUTH_DIR/${name}.adc" \
        "$(_dsbx_secret_marker "$name")" \
        "$_DSBX_AUTH_DIR/${name}.plugin-cache"
fi
```

### `dsbx-build` / `dsbx-check`

Neither needs changes. The cache lives in the sandbox FS, not the image, so
image rebuilds don't affect it. `dsbx-check` only compares image IDs.

## Edge cases

| Case | Behavior |
|---|---|
| Host cache missing entirely | Silent no-op, no error. Bridge finds no skills, sandbox runs normally. |
| Host cache populated, sandbox already has matching contents | Marker fresh → fast skip. |
| Host cache updated since last sync (CC auto-update fired on host) | `find -newer` finds the changed file → re-tar entire tree, touch marker. |
| Host cache file removed | Not detected. Stale file remains in sandbox until `--recreate`. Bridge filtering by `enabledPlugins` masks the impact for the disabled-plugin case. Documented as acceptable. |
| `sbx exec` fails (e.g., daemon down) | Helper returns 1; `_dsbx_run` returns 1 before `sbx run`. Same failure mode as adc/gh-secret. |
| Concurrent `dsbx-omp` invocations on same cwd | Both may sync; tar-extract is idempotent for added files. Marker `touch` race is benign. |
| Host cache enormous (e.g., monorepo plugins) | Linear in cache size; first sync slow, subsequent runs are O(size of changes since marker). |

## Acceptance

1. After `dsbx-build`, fresh `dsbx-omp` invocation populates
   `~/.claude/plugins/cache/` inside the sandbox with the same tree as the host.
2. omp's `claude-skills-bridge` extension registers skills from those plugins
   (verified by listing skills inside omp).
3. Re-running `dsbx-omp` without host cache changes performs the find
   short-circuit and skips the tar copy (verified via `_DSBX_LOG` timing or
   `_DSBX_PROFILE`).
4. After modifying a skill file in the host cache, next `dsbx-omp` re-syncs
   (file mtime newer than marker).
5. `dsbx-omp --recreate` re-seeds the cache into the new sandbox even if host
   cache is unchanged since the last sync (marker cleared as part of recreate).
6. `dsbx-cc` and `dsbx-ruby-cc` continue to function; the extra sync is a no-op
   when host cache is unchanged.

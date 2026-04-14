# Design: Unified nono-agent Function

**Date:** 2026-04-14
**Status:** Draft

## Problem

The nono sandbox aliases for Claude Code and Oh My Pi contain a duplicated 15-line base function (`nono-cc-base`, `nono-omp-base`). The functions are identical except `nono-omp-base` injects two Vertex AI env vars. This duplication means any change to worktree detection, SSH config, or nono flags must be made in two places.

## Approach

Single shared function (`nono-agent`) with agent-specific concerns pushed to the alias/wrapper layer. Shared Vertex AI config extracted into variables for reuse across omp aliases.

## Design

### Shared function: `nono-agent`

Handles all shared nono sandbox logic:
- Git worktree detection and `--read`/`--allow` flag construction
- `GIT_SSH_COMMAND` with custom `known_hosts`
- `nono run --allow-cwd --override-deny ~/.config/gcloud`
- Passes all remaining arguments through to `nono run`

```zsh
nono-agent() {
  local worktree_args=()
  local git_common_dir
  if git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)"; then
    local source_repo="$(cd "$git_common_dir/.." && pwd)"
    if [[ "$source_repo" != "$(pwd)" ]]; then
      local git_dir abs_common_dir
      git_dir="$(git rev-parse --absolute-git-dir)"
      abs_common_dir="$(cd "$git_common_dir" && pwd)"
      worktree_args=(--read "$source_repo" --allow "$git_dir" --allow "$abs_common_dir")
    fi
  fi

  GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=$HOME/dotfiles/dot-config/nono/known_hosts" \
    nono run --allow-cwd --override-deny ~/.config/gcloud "${worktree_args[@]}" "$@"
}
```

### Shared variables

OMP-specific Vertex AI config defined once, interpolated into alias definitions at parse time:

```zsh
_OMP_VERTEX="GOOGLE_CLOUD_PROJECT=consolo-dev-vertex-wsky GOOGLE_CLOUD_LOCATION=us-east5"
_OMP_MODEL="anthropic-vertex/claude-opus-4-6"
```

### Claude Code aliases

No env var prefix needed. Profile and command vary per variant.

```zsh
alias nono-cc='nono-agent --profile claude-code-mise -- claude --dangerously-skip-permissions'
nono-cc-personal() { OP_ACCOUNT=my.1password.com nono-agent --profile claude-code-personal -- claude --dangerously-skip-permissions "$@"; }
alias nono-cc-csharp='nono-agent --profile claude-code-csharp -- claude --dangerously-skip-permissions'
```

### Oh My Pi aliases

Vertex AI env vars and model baked in via variable interpolation. `nono-omp-personal` uses `env ${=_OMP_VERTEX}` for word-splitting (avoids `eval`).

```zsh
alias nono-omp="$_OMP_VERTEX nono-agent --profile omp-mise -- omp --model $_OMP_MODEL"
nono-omp-personal() { env ${=_OMP_VERTEX} OP_ACCOUNT=my.1password.com nono-agent --profile omp-personal -- omp --model $_OMP_MODEL "$@"; }
alias nono-omp-csharp="$_OMP_VERTEX nono-agent --profile omp-csharp -- omp --model $_OMP_MODEL"
```

### Bare omp/pi aliases

Also use shared variables:

```zsh
alias omp="$_OMP_VERTEX command omp --model $_OMP_MODEL"
alias pi="$_OMP_VERTEX command pi --model $_OMP_MODEL"
```

### New nono profile: `omp-csharp`

Mirrors `claude-code-csharp` — extends `omp-mise`, adds .NET/NuGet filesystem access.

```json
{
  "meta": {
    "name": "omp-csharp",
    "description": "Oh My Pi profile with mise and NuGet package access for C# development"
  },
  "extends": "omp-mise",
  "filesystem": {
    "allow": [
      "$HOME/.nuget",
      "$HOME/.dotnet",
      "$XDG_DATA_HOME/NuGet",
      "/tmp/NuGetScratch"
    ]
  }
}
```

## Files changed

| File | Change |
|---|---|
| `dot-zshrc` | Replace `nono-cc-base` + `nono-omp-base` with `nono-agent`, shared vars, updated aliases |
| `dot-config/nono/profiles/omp-csharp.json` | New profile |

## What gets deleted

- `nono-cc-base` function (16 lines)
- `nono-omp-base` function (18 lines)

## Net result

- Worktree detection logic: 2 copies -> 1
- OMP Vertex AI config: repeated on every omp alias -> defined once
- Total lines: ~40 -> ~25

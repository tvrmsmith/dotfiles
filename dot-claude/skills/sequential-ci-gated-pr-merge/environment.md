# Environment gotchas

- **`gh` often aliased to `op plugin run -- gh`** (1Password). Reads work, but writes/auth can intermittently fail with "authorization timeout" — just retry command (output is not truncated by the RTK proxy — suspect 1Password auth or a still-computing status rollup).
- **macOS bash:** only `/bin/bash` (3.2) may exist; Homebrew bash may be absent. `pr-monitor.sh` uses `#!/bin/bash` shebang, stays 3.2-compatible. Some other tooling (e.g. local `imr` verify) needs `PATH=/opt/homebrew/bin:$PATH` — set for those, not for monitor.
- **Worktree auth timeouts:** running `gh` from inside certain git worktrees can hit auth-timeout. Running from plain repo dir (e.g. `~/dev`) more reliable for read APIs. Always pass `--repo <owner>/<name>` explicitly regardless of cwd.

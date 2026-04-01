# Running Claude Code in a nono Sandbox

[nono](https://github.com/always-further/nono) is a capability-based sandbox that provides OS-enforced filesystem and network isolation for AI coding agents. This guide walks through sandboxing Claude Code with nono so that it can only access the files and credentials you explicitly allow.

## Why Sandbox Claude Code?

Claude Code has direct access to your filesystem, shell, and any credentials reachable from your terminal. In a normal session where you're watching every tool call, this is manageable. But the risk profile changes significantly in two scenarios:

### Unattended and long-running sessions

Claude Code sessions can run for extended periods — implementing a feature, running test suites, iterating on failures. During these sessions you're likely context-switching to other work, reviewing a PR, or away from your desk entirely. Without a sandbox, a misbehaving tool call can read or modify files outside the project, access credentials you didn't intend to expose, or execute destructive commands. The sandbox ensures that even if you aren't watching, the blast radius is limited to exactly what you granted.

### Subagent-driven development

Modern Claude Code workflows dispatch multiple subagents in parallel — one researching the codebase, another writing tests, another implementing a feature, potentially across separate git worktrees. Each subagent inherits the parent session's full filesystem and shell access. This multiplies the surface area: instead of one agent you're monitoring, you have several running concurrently, each making independent tool calls. A sandbox around the parent session constrains all subagents to the same boundary. No subagent can reach outside the allowed paths regardless of what it's asked to do.

### Prompt injection and untrusted content

Claude Code reads files from your project — markdown, config files, dependency manifests, API responses. Any of these could contain adversarial content designed to manipulate the agent into exfiltrating data or modifying files outside the project. A sandbox makes these attacks ineffective: even if the agent is tricked into attempting a malicious action, the OS-level enforcement blocks it before it reaches the filesystem.

### Defense in depth

Claude Code already has its own permission system (the `permissions` block in `settings.json`) and requires user approval for certain operations. The sandbox is a separate, independent layer enforced by the operating system — not by the agent itself. This means:

- Claude Code's permission system protects against **accidental** overreach
- The nono sandbox protects against **everything else** — bugs, prompt injection, misconfigured permissions, or any scenario where the agent's own guardrails might not be enough

The two layers complement each other. The sandbox is the hard boundary; Claude Code's permissions are the ergonomic one.

## Install nono

```bash
brew install nono
nono setup
```

## Quick Start

The simplest way to run Claude Code sandboxed:

```bash
nono run --profile claude-code --allow-cwd -- claude
```

This uses nono's built-in `claude-code` profile which:

- Grants read+write to `~/.claude` and `~/.claude.json` (Claude Code's own config)
- Grants read+write to the current working directory
- Denies access to credentials, keychains, browser data, shell history, and shell configs
- Blocks dangerous commands (`rm -rf /`, `mkfs`, etc.)
- Allows network access (required for the Claude API)
- Installs a diagnostic hook that tells Claude when it hits a sandbox boundary, preventing it from retrying blocked operations in a loop

You can inspect the full profile with:

```bash
nono policy show claude-code
```

## Custom Profiles

nono profiles live in `~/.config/nono/profiles/` as JSON files. You can extend the built-in `claude-code` profile to grant additional access for your toolchain.

### Example: mise runtime manager profile

This profile extends `claude-code` to allow access to [mise](https://mise.jdx.dev/) (runtime version manager), gcloud credentials (read-only), 1Password SSH agent, and dotfiles:

```json
{
  "meta": {
    "name": "claude-code-mise",
    "description": "Claude Code profile with mise runtime manager and gcloud access"
  },
  "extends": "claude-code",
  "filesystem": {
    "allow": [
      "$XDG_DATA_HOME/mise",
      "$HOME/.cache/mise",
      "$HOME/.local/state/mise",
      "$HOME/Library/Group Containers/2BUA8C4S2C.com.1password"
    ],
    "read": [
      "$HOME/.config/gcloud",
      "$HOME/.ssh/1Password",
      "$HOME/dotfiles/dot-claude"
    ],
    "read_file": [
      "$HOME/.gitignore",
      "$HOME/dotfiles/dot-config/nono/known_hosts"
    ]
  }
}
```

Save this as `~/.config/nono/profiles/claude-code-mise.json`.

### Example: C# / .NET profile

Profiles can extend other custom profiles. This one builds on the mise profile above to add NuGet and .NET SDK access:

```json
{
  "meta": {
    "name": "claude-code-csharp",
    "description": "Claude Code profile with mise and NuGet package access for C# development"
  },
  "extends": "claude-code-mise",
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

### Profile filesystem permissions

| Key          | Access     | Scope           |
|--------------|------------|-----------------|
| `allow`      | read+write | directory (recursive) |
| `read`       | read-only  | directory (recursive) |
| `read_file`  | read-only  | single file     |
| `allow_file` | read+write | single file     |

## Shell Aliases

These aliases compose the profiles with useful flags for daily use:

```bash
# Base alias — sets up SSH known_hosts and gcloud override (see below)
alias nono-cc-base='GIT_SSH_COMMAND="ssh -o UserKnownHostsFile=$HOME/dotfiles/dot-config/nono/known_hosts" nono run --allow-cwd --override-deny ~/.config/gcloud'

# General development (mise profile)
alias nono-cc='nono-cc-base --profile claude-code-mise -- claude'

# C# development (adds .nuget/.dotnet access)
alias nono-cc-csharp='nono-cc-base --profile claude-code-csharp -- claude'
```

Add these to your `.zshrc` or `.bashrc`.

### What the base alias does

- **`GIT_SSH_COMMAND`** — Points SSH at a dedicated `known_hosts` file that nono can read. The sandbox blocks access to `~/.ssh/known_hosts` by default, which would cause git push/pull over SSH to fail with host verification errors. Create this file with the hosts you need:

  ```bash
  ssh-keyscan github.com > ~/.config/nono/known_hosts
  ```

- **`--allow-cwd`** — Grants read+write access to whatever directory you launch from (your project root).

- **`--override-deny ~/.config/gcloud`** — Explained in the next section.

## Using gcloud Credentials

The built-in `claude-code` profile includes a `deny_credentials` security group that blocks access to credential stores, including `~/.config/gcloud`. If Claude Code needs to authenticate with Google Cloud (e.g., for Vertex AI), you need to override this deny rule.

The `--override-deny` flag lifts a specific deny rule so that a corresponding allow/read grant can take effect:

```bash
nono run --profile claude-code-mise --allow-cwd --override-deny ~/.config/gcloud -- claude
```

This works because the `claude-code-mise` profile already has `~/.config/gcloud` listed under `read` (read-only access). Without `--override-deny`, the deny rule from the `deny_credentials` security group would take precedence over the read grant. The override removes the deny, allowing the read grant to apply.

**Key point:** `--override-deny` does not grant access by itself. It only removes a deny rule. You still need a corresponding `allow`, `read`, or `read_file` grant — either in your profile or on the command line — for the path to actually be accessible.

If you don't use a profile that grants gcloud read access, combine both flags:

```bash
nono run --profile claude-code --allow-cwd --override-deny ~/.config/gcloud --read ~/.config/gcloud -- claude
```

## Adding Access for Your Toolchain

When Claude Code fails because a tool needs a path outside the sandbox, you have two options:

### 1. Ad-hoc flags (one-off)

Add `--allow`, `--read`, or `--read-file` on the command line:

```bash
nono run --profile claude-code --allow-cwd --allow ~/.cargo -- claude
```

### 2. Custom profile (persistent)

Create a new profile in `~/.config/nono/profiles/` that extends an existing one:

```json
{
  "meta": {
    "name": "claude-code-rust",
    "description": "Claude Code with Rust toolchain access"
  },
  "extends": "claude-code",
  "filesystem": {
    "allow": [
      "$HOME/.cargo",
      "$HOME/.rustup"
    ]
  }
}
```

Then use it:

```bash
nono run --profile claude-code-rust --allow-cwd -- claude
```

### Discovering what paths a tool needs

Use `nono learn` to trace a command and see what filesystem paths it accesses:

```bash
nono learn -- dotnet build
```

This shows every path the command reads or writes, which you can then add to your profile.

## Useful nono Commands

```bash
# See what a profile allows
nono policy show claude-code

# Check why a specific path would be allowed or denied
nono why ~/.config/gcloud --profile claude-code

# Dry run — show sandbox config without executing
nono run --profile claude-code --allow-cwd --dry-run -- claude

# Trace a command to discover required paths
nono learn -- <command>
```

## Links

- [nono GitHub](https://github.com/always-further/nono)
- [Claude Code Hooks documentation](https://docs.anthropic.com/en/docs/claude-code/hooks)

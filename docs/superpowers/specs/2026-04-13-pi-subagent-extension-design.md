# Pi Subagent Extension Design

**Date:** 2026-04-13
**Status:** Approved

## Goal

Add subagent support to Pi by installing the upstream subagent extension from `pi-mono`, bridging Claude Code plugin agents into Pi's discovery system, and sharing personal agent definitions between Claude Code and Pi.

## Architecture

### Repository Setup

- Fork `badlogic/pi-mono` to `tvrmsmith/pi-mono`
- Clone to `~/dev/pi-mono`
- Maintain a `trevor/custom-agents` branch with two patches (see Fork Changes below)
- Rebase on upstream as needed

### Agent Discovery Flow

```
Pi session starts
  │
  ├── resources_discover event fires
  │     │
  │     ├── claude-agents-bridge.ts
  │     │     reads ~/.claude/settings.json
  │     │     scans plugin cache for agents/ dirs
  │     │     returns { agentPaths: [...] }
  │     │
  │     └── claude-skills-bridge.ts (existing)
  │           returns { skillPaths: [...] }
  │
  ├── subagent tool invoked
  │     │
  │     ├── discoverAgents() runs:
  │     │     1. ~/.pi/agent/agents/ (user dir — symlinked to ~/.claude/agents/)
  │     │     2. .pi/agents/ (project dir, walked up from cwd)
  │     │     3. extension-local agents/ subdir (bundled scout/planner/reviewer/worker)
  │     │     4. agentPaths from resources_discover (plugin agents)
  │     │
  │     └── agent spawned as isolated pi subprocess
```

### Agent Sources (priority low → high)

| Source | Location | Contains |
|--------|----------|----------|
| Extension-local | `subagent/agents/` (bundled in symlink) | scout, planner, reviewer, worker |
| User agents | `~/.pi/agent/agents/` → `~/.claude/agents/` | architecture-compliance-reviewer, future personal agents |
| Plugin agents | `~/.claude/plugins/cache/<mkt>/<plugin>/<ver>/agents/` | Agents from enabled Claude Code plugins |
| Project agents | `.pi/agents/` (repo-local) | Per-project agent overrides |

Same-name agents: later source overrides earlier. Project agents override everything.

## Fork Changes (`tvrmsmith/pi-mono`, branch `trevor/custom-agents`)

### 1. `packages/coding-agent/examples/extensions/subagent/agents.ts`

Modify `discoverAgents()`:

- Accept optional `extraDirs?: string[]` parameter
- Load agents from each extra dir as `"user"` source
- Add extension-local discovery via `import.meta.url`

```typescript
export function discoverAgents(
  cwd: string,
  scope: AgentScope,
  extraDirs?: string[]
): AgentDiscoveryResult {
  const userDir = path.join(getAgentDir(), "agents");
  const extensionAgentsDir = path.join(
    path.dirname(new URL(import.meta.url).pathname),
    "agents"
  );
  const projectAgentsDir = findNearestProjectAgentsDir(cwd);

  const userAgents = scope === "project" ? [] : loadAgentsFromDir(userDir, "user");
  const extensionAgents = scope === "project" ? [] : loadAgentsFromDir(extensionAgentsDir, "user");
  const extraAgents = scope === "project"
    ? []
    : (extraDirs ?? []).flatMap(dir => loadAgentsFromDir(dir, "user"));
  const projectAgents = scope === "user" || !projectAgentsDir
    ? []
    : loadAgentsFromDir(projectAgentsDir, "project");

  const agentMap = new Map<string, AgentConfig>();

  // Load order determines override priority (last wins)
  if (scope !== "project") {
    for (const agent of extensionAgents) agentMap.set(agent.name, agent);
    for (const agent of extraAgents) agentMap.set(agent.name, agent);
    for (const agent of userAgents) agentMap.set(agent.name, agent);
  }
  if (scope !== "user") {
    for (const agent of projectAgents) agentMap.set(agent.name, agent);
  }

  return { agents: Array.from(agentMap.values()), projectAgentsDir };
}
```

### 2. `packages/coding-agent/examples/extensions/subagent/index.ts`

In the `execute` function, gather `agentPaths` from resource discovery before calling `discoverAgents()`:

```typescript
// Inside execute(), before discovery
const discoveredResources = pi.getDiscoveredResources();
const extraAgentDirs = discoveredResources?.agentPaths ?? [];
const discovery = discoverAgents(ctx.cwd, agentScope, extraAgentDirs);
```

## Dotfiles Changes

### New Files

**`dot-pi/agent/extensions/claude-agents-bridge.ts`**

Discovers agent definitions from enabled Claude Code marketplace plugins. Mirrors the existing `claude-skills-bridge.ts` pattern:

```typescript
import { readFileSync, readdirSync, existsSync, statSync } from "fs";
import { join } from "path";
import { homedir } from "os";

interface ClaudeSettings {
  enabledPlugins?: Record<string, boolean>;
}

export default async function (pi: any) {
  const home = homedir();
  const settingsPath = join(home, ".claude", "settings.json");
  const cacheDir = join(home, ".claude", "plugins", "cache");

  if (!existsSync(settingsPath) || !existsSync(cacheDir)) return;

  let settings: ClaudeSettings;
  try {
    settings = JSON.parse(readFileSync(settingsPath, "utf-8"));
  } catch {
    return;
  }

  const enabledPlugins = settings.enabledPlugins ?? {};
  const enabled = new Set<string>();
  for (const [key, value] of Object.entries(enabledPlugins)) {
    if (value) enabled.add(key);
  }

  const agentPaths: string[] = [];

  for (const marketplace of safeReaddir(cacheDir)) {
    const marketplaceDir = join(cacheDir, marketplace);
    if (!isDir(marketplaceDir)) continue;

    for (const plugin of safeReaddir(marketplaceDir)) {
      const pluginDir = join(marketplaceDir, plugin);
      if (!isDir(pluginDir)) continue;

      const pluginKey = `${plugin}@${marketplace}`;
      if (!enabled.has(pluginKey)) continue;

      const versions = safeReaddir(pluginDir).filter(v => isDir(join(pluginDir, v)));
      if (versions.length === 0) continue;

      const versionDir = join(pluginDir, versions[versions.length - 1]);
      const agentsDir = join(versionDir, "agents");

      if (existsSync(agentsDir) && isDir(agentsDir)) {
        agentPaths.push(agentsDir);
      }
    }
  }

  if (agentPaths.length === 0) return;

  pi.on("resources_discover", () => {
    return {
      skillPaths: [] as string[],
      promptPaths: [] as string[],
      themePaths: [] as string[],
      agentPaths,
    };
  });
}

function safeReaddir(dir: string): string[] {
  try { return readdirSync(dir); } catch { return []; }
}

function isDir(path: string): boolean {
  try { return statSync(path).isDirectory(); } catch { return false; }
}
```

### New Symlinks

| Dotfiles path | Target |
|---------------|--------|
| `dot-pi/agent/extensions/subagent` | `~/dev/pi-mono/packages/coding-agent/examples/extensions/subagent` |
| `dot-pi/agent/agents` | Symlink to `~/.claude/agents` (absolute target, created by install script or manually) |

### Upstream Prompts

The symlinked `subagent/prompts/` dir provides workflow templates:

- `/implement <query>` — scout -> planner -> worker
- `/scout-and-plan <query>` — scout -> planner
- `/implement-and-review <query>` — worker -> reviewer -> worker

These are available automatically via the extension symlink. No dotfiles changes needed.

## What's NOT Included

- No new agent `.md` definitions — upstream scout/planner/reviewer/worker cover general-purpose and explore use cases
- No modifications to the existing `claude-skills-bridge.ts`
- No changes to `dot-claude/settings.json`

## Risk

- **`resources_discover` return shape:** If Pi validates strictly and rejects unknown keys like `agentPaths`, plugin agent discovery silently fails. User and extension-local agents still work. Mitigation: test early, fall back to symlink approach if needed.
- **Fork maintenance:** Branch needs periodic rebase on upstream. Small patch surface (two files, minimal changes) keeps conflicts unlikely.
- **Agents symlink:** `dot-pi/agent/agents` → `~/.claude/agents` uses an absolute target, bypassing stow for this path. Created manually or via install script since stow can't manage cross-target symlinks.

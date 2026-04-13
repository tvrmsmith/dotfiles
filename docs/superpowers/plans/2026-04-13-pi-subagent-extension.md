# Pi Subagent Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add subagent support to Pi by installing the upstream subagent extension from a fork of `pi-mono`, bridging Claude Code plugin agents into Pi's discovery, and sharing personal agent definitions between Claude Code and Pi.

**Architecture:** Fork `badlogic/pi-mono` to `tvrmsmith/pi-mono`, maintain a `trevor/custom-agents` branch with two patches (extension-local agent discovery + `agentPaths` from `resources_discover`). Symlink the upstream subagent extension into dotfiles. Write a `claude-agents-bridge.ts` that discovers agent `.md` files from enabled Claude Code plugins. Symlink `dot-pi/agent/agents` to `dot-claude/agents` so personal agents are shared.

**Tech Stack:** TypeScript (Pi extensions), Git (fork management), GNU Stow (dotfiles symlinks)

**Spec:** `docs/superpowers/specs/2026-04-13-pi-subagent-extension-design.md`

---

### Task 1: Fork and Clone pi-mono

**Files:**
- None in dotfiles repo (external repo setup)

- [ ] **Step 1: Switch to tvrmsmith GitHub account**

```bash
gh auth switch --user tvrmsmith
```

Expected: `Switched active account for github.com to tvrmsmith`

- [ ] **Step 2: Fork badlogic/pi-mono**

```bash
gh repo fork badlogic/pi-mono --clone=false
```

Expected: `Created fork tvrmsmith/pi-mono`

If fork already exists, this is a no-op.

- [ ] **Step 3: Clone to ~/dev**

```bash
git clone github-personal:tvrmsmith/pi-mono.git ~/dev/pi-mono
```

Uses the `github-personal` SSH host alias per global git config for `tvrmsmith/*` repos.

Expected: Clone completes into `~/dev/pi-mono/`

- [ ] **Step 4: Add upstream remote and create branch**

```bash
cd ~/dev/pi-mono
git remote add upstream https://github.com/badlogic/pi-mono.git
git fetch upstream
git checkout -b trevor/custom-agents
```

Expected: On branch `trevor/custom-agents` tracking local.

- [ ] **Step 5: Commit (nothing to commit yet — branch created)**

Verify branch:

```bash
git branch --show-current
```

Expected: `trevor/custom-agents`

---

### Task 2: Patch agents.ts — Extension-Local Discovery + extraDirs

**Files:**
- Modify: `~/dev/pi-mono/packages/coding-agent/examples/extensions/subagent/agents.ts`

- [ ] **Step 1: Read the current `discoverAgents` function**

Open `~/dev/pi-mono/packages/coding-agent/examples/extensions/subagent/agents.ts` and locate the `discoverAgents` function. Note the existing signature and body.

- [ ] **Step 2: Modify `discoverAgents` to accept `extraDirs` and discover extension-local agents**

Replace the existing `discoverAgents` function with:

```typescript
export function discoverAgents(cwd: string, scope: AgentScope, extraDirs?: string[]): AgentDiscoveryResult {
	const userDir = path.join(getAgentDir(), "agents");
	const extensionAgentsDir = path.join(path.dirname(new URL(import.meta.url).pathname), "agents");
	const projectAgentsDir = findNearestProjectAgentsDir(cwd);

	const userAgents = scope === "project" ? [] : loadAgentsFromDir(userDir, "user");
	const extensionAgents = scope === "project" ? [] : loadAgentsFromDir(extensionAgentsDir, "user");
	const extraAgents = scope === "project"
		? []
		: (extraDirs ?? []).flatMap((dir) => loadAgentsFromDir(dir, "user"));
	const projectAgents = scope === "user" || !projectAgentsDir ? [] : loadAgentsFromDir(projectAgentsDir, "project");

	const agentMap = new Map<string, AgentConfig>();

	// Load order determines override priority (last wins)
	// extension-local < extra (plugin) < user < project
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

Key changes from upstream:
- Added `extraDirs?: string[]` parameter
- Added `extensionAgentsDir` using `import.meta.url` to resolve the `agents/` subdir relative to the extension
- Added `extraAgents` loaded from `extraDirs`
- Load order: extension-local → extra (plugin) → user → project

- [ ] **Step 3: Verify the file is valid TypeScript**

```bash
cd ~/dev/pi-mono
npx tsc --noEmit packages/coding-agent/examples/extensions/subagent/agents.ts 2>&1 || echo "Type check skipped — may need full project build context"
```

If tsc fails due to missing project context, that's OK — the change is a minimal signature extension. Verify manually that the function compiles by reading it back.

- [ ] **Step 4: Commit**

```bash
cd ~/dev/pi-mono
git add packages/coding-agent/examples/extensions/subagent/agents.ts
git commit -m "feat(subagent): add extension-local agent discovery and extraDirs param

discoverAgents() now checks for .md files in the extension's own
agents/ subdir and accepts optional extraDirs for plugin-sourced agents.

Priority: extension-local < extra (plugin) < user < project.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 3: Patch index.ts — Consume agentPaths from resources_discover

**Files:**
- Modify: `~/dev/pi-mono/packages/coding-agent/examples/extensions/subagent/index.ts`

- [ ] **Step 1: Read the current execute function in index.ts**

Open `~/dev/pi-mono/packages/coding-agent/examples/extensions/subagent/index.ts` and locate:
1. The `execute` method inside `pi.registerTool({ ... })`
2. The line where `discoverAgents()` is called
3. The existing import of `discoverAgents` from `./agents.js`

- [ ] **Step 2: Store the `pi` reference for use inside execute**

The `execute` function needs access to `pi` (the `ExtensionAPI` instance) to call `pi.getDiscoveredResources()`. The `pi` variable is already in closure scope from the default export function — verify this is accessible inside the tool's `execute` method. It should be, since the tool is registered in the same function scope.

- [ ] **Step 3: Add agentPaths consumption before discoverAgents call**

Find the line in `execute` that calls `discoverAgents()`. It will look like:

```typescript
const discovery = discoverAgents(ctx.cwd, agentScope);
```

Replace with:

```typescript
const discoveredResources = pi.getDiscoveredResources?.() ?? {};
const extraAgentDirs: string[] = (discoveredResources as any).agentPaths ?? [];
const discovery = discoverAgents(ctx.cwd, agentScope, extraAgentDirs);
```

Note: `(discoveredResources as any)` handles the case where `agentPaths` isn't in Pi's type definition yet. The `?.()` optional call handles the case where `getDiscoveredResources` doesn't exist on the `ExtensionAPI` type.

- [ ] **Step 4: Commit**

```bash
cd ~/dev/pi-mono
git add packages/coding-agent/examples/extensions/subagent/index.ts
git commit -m "feat(subagent): consume agentPaths from resources_discover

Passes agentPaths (registered by bridge extensions) as extraDirs
to discoverAgents(), enabling plugin-sourced agent discovery.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 4: Push Fork Branch

**Files:**
- None (git operations only)

- [ ] **Step 1: Ensure tvrmsmith GitHub account is active**

```bash
gh auth switch --user tvrmsmith
```

- [ ] **Step 2: Push branch to origin**

```bash
cd ~/dev/pi-mono
git push -u origin trevor/custom-agents
```

Expected: Branch pushed to `tvrmsmith/pi-mono`.

---

### Task 5: Create Subagent Extension Symlink in Dotfiles

**Files:**
- Create symlink: `dot-pi/agent/extensions/subagent` → `~/dev/pi-mono/packages/coding-agent/examples/extensions/subagent`

- [ ] **Step 1: Verify target exists**

```bash
ls ~/dev/pi-mono/packages/coding-agent/examples/extensions/subagent/index.ts
```

Expected: File exists.

- [ ] **Step 2: Create symlink**

```bash
cd ~/dotfiles
ln -s ~/dev/pi-mono/packages/coding-agent/examples/extensions/subagent dot-pi/agent/extensions/subagent
```

- [ ] **Step 3: Verify symlink resolves**

```bash
ls -la dot-pi/agent/extensions/subagent/
```

Expected: Shows `index.ts`, `agents.ts`, `agents/`, `prompts/`, `README.md`.

- [ ] **Step 4: Verify stow will propagate it**

```bash
stow --dotfiles -n -v -t "$HOME" .
```

The `-n` flag is dry-run. Look for `~/.pi/agent/extensions/subagent` in the output.

- [ ] **Step 5: Commit**

```bash
git add dot-pi/agent/extensions/subagent
git commit -m "feat: symlink upstream subagent extension from pi-mono fork

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 6: Create Agents Directory Symlink

**Files:**
- Create symlink: `dot-pi/agent/agents` → absolute path to `~/.claude/agents`

- [ ] **Step 1: Verify dot-claude/agents exists and contains agent definitions**

```bash
ls ~/dotfiles/dot-claude/agents/
```

Expected: `architecture-compliance-reviewer.md`

- [ ] **Step 2: Create the symlink in dotfiles**

This symlink points to the stow-managed `~/.claude/agents` directory (absolute target) so that both Claude Code and Pi share the same agent definitions:

```bash
cd ~/dotfiles
ln -s "$HOME/.claude/agents" dot-pi/agent/agents
```

- [ ] **Step 3: Verify symlink**

```bash
ls -la dot-pi/agent/agents
```

Expected: Symlink pointing to `/Users/trevor.smith/.claude/agents`.

```bash
ls dot-pi/agent/agents/
```

Expected: `architecture-compliance-reviewer.md`

- [ ] **Step 4: Commit**

```bash
git add dot-pi/agent/agents
git commit -m "feat: symlink Pi agents dir to Claude agents for shared definitions

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 7: Write claude-agents-bridge.ts

**Files:**
- Create: `dot-pi/agent/extensions/claude-agents-bridge.ts`

- [ ] **Step 1: Read the existing claude-skills-bridge.ts for reference**

Open `dot-pi/agent/extensions/claude-skills-bridge.ts`. The new file mirrors this structure exactly, but scans for `agents/` dirs instead of `skills/` dirs.

- [ ] **Step 2: Create claude-agents-bridge.ts**

Create `dot-pi/agent/extensions/claude-agents-bridge.ts` with:

```typescript
import { readFileSync, readdirSync, existsSync, statSync } from "fs";
import { join } from "path";
import { homedir } from "os";

interface EnabledPlugins {
	[key: string]: boolean;
}

interface ClaudeSettings {
	enabledPlugins?: EnabledPlugins;
}

/**
 * Pi extension that discovers agent definitions from Claude Code's
 * installed marketplace plugins.
 *
 * Reads ~/.claude/settings.json to determine which plugins are enabled,
 * then resolves their agent directories from the plugin cache and
 * registers them via pi's resources_discover event.
 */
export default async function (pi: any) {
	const home = homedir();
	const settingsPath = join(home, ".claude", "settings.json");
	const cacheDir = join(home, ".claude", "plugins", "cache");

	if (!existsSync(settingsPath) || !existsSync(cacheDir)) {
		return;
	}

	let settings: ClaudeSettings;
	try {
		settings = JSON.parse(readFileSync(settingsPath, "utf-8"));
	} catch {
		return;
	}

	const enabledPlugins = settings.enabledPlugins ?? {};

	// Build a set of enabled plugin@marketplace pairs
	// Format in settings.json: "plugin@marketplace": true/false
	const enabled = new Set<string>();
	for (const [key, value] of Object.entries(enabledPlugins)) {
		if (value) {
			enabled.add(key);
		}
	}

	// Scan cache directory: cache/<marketplace>/<plugin>/<version>/agents/
	const agentPaths: string[] = [];

	for (const marketplace of safeReaddir(cacheDir)) {
		const marketplaceDir = join(cacheDir, marketplace);
		if (!isDir(marketplaceDir)) continue;

		for (const plugin of safeReaddir(marketplaceDir)) {
			const pluginDir = join(marketplaceDir, plugin);
			if (!isDir(pluginDir)) continue;

			// Check if this plugin is enabled
			const pluginKey = `${plugin}@${marketplace}`;
			if (!enabled.has(pluginKey)) continue;

			// Find the latest version directory (there's usually only one)
			const versions = safeReaddir(pluginDir).filter((v) =>
				isDir(join(pluginDir, v))
			);
			if (versions.length === 0) continue;

			// Use last entry (versions sort lexically, newest cached last)
			const versionDir = join(pluginDir, versions[versions.length - 1]);
			const agentsDir = join(versionDir, "agents");

			if (existsSync(agentsDir) && isDir(agentsDir)) {
				agentPaths.push(agentsDir);
			}
		}
	}

	if (agentPaths.length === 0) return;

	// Register discovered agent paths via pi's resource discovery event
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
	try {
		return readdirSync(dir);
	} catch {
		return [];
	}
}

function isDir(path: string): boolean {
	try {
		return statSync(path).isDirectory();
	} catch {
		return false;
	}
}
```

- [ ] **Step 3: Verify the file exists and looks correct**

```bash
head -5 dot-pi/agent/extensions/claude-agents-bridge.ts
```

Expected: Shows the import statements.

- [ ] **Step 4: Commit**

```bash
git add dot-pi/agent/extensions/claude-agents-bridge.ts
git commit -m "feat: add Claude agents bridge extension for Pi

Discovers agent .md files from enabled Claude Code marketplace
plugins and registers their paths via resources_discover for
the subagent tool to consume.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

---

### Task 8: Run Stow and Verify End-to-End

**Files:**
- None (verification only)

- [ ] **Step 1: Run stow to propagate dotfiles**

```bash
cd ~/dotfiles
stow --dotfiles -t "$HOME" .
```

Expected: No errors.

- [ ] **Step 2: Verify subagent extension is in place**

```bash
ls ~/.pi/agent/extensions/subagent/index.ts
```

Expected: File exists (resolved through symlink chain: stow → dotfiles → pi-mono fork).

- [ ] **Step 3: Verify agents symlink resolves**

```bash
ls ~/.pi/agent/agents/
```

Expected: `architecture-compliance-reviewer.md` (resolved through symlink to `~/.claude/agents/`).

- [ ] **Step 4: Verify bridge extension is in place**

```bash
ls ~/.pi/agent/extensions/claude-agents-bridge.ts
```

Expected: File exists.

- [ ] **Step 5: Verify upstream bundled agents are discoverable**

```bash
ls ~/.pi/agent/extensions/subagent/agents/
```

Expected: `scout.md`, `planner.md`, `reviewer.md`, `worker.md`

- [ ] **Step 6: Verify upstream prompts are discoverable**

```bash
ls ~/.pi/agent/extensions/subagent/prompts/
```

Expected: `implement.md`, `scout-and-plan.md`, `implement-and-review.md`

- [ ] **Step 7: Smoke test in Pi (manual)**

Launch Pi and verify:
1. The subagent extension loads without errors (check for errors on startup)
2. Run a simple subagent invocation: ask Pi to "use scout to find all TypeScript files in this directory"
3. Verify the agent list includes: scout, planner, reviewer, worker, architecture-compliance-reviewer

If `agentPaths`/`getDiscoveredResources` fails silently (risk noted in spec), extension-local and user agents still work — plugin agents just won't appear.

---

### Task 9: Update .stow-local-ignore (if needed)

**Files:**
- Modify: `.stow-local-ignore`

- [ ] **Step 1: Check if docs/ gets stowed**

```bash
stow --dotfiles -n -v -t "$HOME" . 2>&1 | grep docs
```

If `docs/` appears in the output, it would create `~/.docs/` which is unwanted.

- [ ] **Step 2: Add docs to ignore if needed**

If step 1 shows docs being stowed, add to `.stow-local-ignore`:

```
^/docs
```

If docs is NOT being stowed (e.g., stow doesn't process it because it doesn't start with `dot-`), skip this step — no change needed.

- [ ] **Step 3: Commit (only if changes made)**

```bash
git add .stow-local-ignore
git commit -m "chore: ignore docs/ directory from stow

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>"
```

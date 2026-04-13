import { readFileSync, readdirSync, existsSync, statSync } from "fs";
import { join, resolve } from "path";
import { homedir } from "os";

interface EnabledPlugins {
	[key: string]: boolean;
}

interface ClaudeSettings {
	enabledPlugins?: EnabledPlugins;
}

/**
 * Pi extension that discovers and loads skills from Claude Code's
 * installed marketplace plugins.
 *
 * Reads ~/.claude/settings.json to determine which plugins are enabled,
 * then resolves their skill directories from the plugin cache and
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

	// Scan cache directory: cache/<marketplace>/<plugin>/<version>/skills/
	const skillPaths: string[] = [];

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
			const skillsDir = join(versionDir, "skills");

			if (existsSync(skillsDir) && isDir(skillsDir)) {
				skillPaths.push(skillsDir);
			}
		}
	}

	if (skillPaths.length === 0) return;

	// Register discovered skill paths via pi's resource discovery event
	pi.on("resources_discover", () => {
		return {
			skillPaths,
			promptPaths: [] as string[],
			themePaths: [] as string[],
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

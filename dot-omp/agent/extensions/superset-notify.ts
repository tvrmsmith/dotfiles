/**
 * Superset Notification Extension for Oh My Pi
 *
 * Notifies Superset's terminal TUI when the agent starts, stops, or
 * needs a permission decision.  Mirrors the behavior of the existing
 * Claude Code and OpenCode hooks shipped in ~/.superset/hooks/.
 *
 * Events mapped:
 *   agent_start  → Start   (agent begins processing)
 *   agent_end    → Stop    (agent finishes, waiting for input)
 *   tool_call    → Start   (tool running — keeps "busy" state)
 */
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

export default function supersetNotify(pi: ExtensionAPI) {
	pi.setLabel("Superset Notifications");

	const tabId = process.env.SUPERSET_TAB_ID;
	if (!tabId) return; // not inside a Superset terminal

	const paneId = process.env.SUPERSET_PANE_ID ?? "";
	const workspaceId = process.env.SUPERSET_WORKSPACE_ID ?? "";
	const port = process.env.SUPERSET_PORT ?? "51741";
	const env = process.env.SUPERSET_ENV ?? "";
	const hookVersion = process.env.SUPERSET_HOOK_VERSION ?? "";
	const debug =
		process.env.SUPERSET_DEBUG_HOOKS === "1" ||
		process.env.SUPERSET_DEBUG === "1";

	const log = (...args: unknown[]) => {
		if (debug) console.log("[superset-omp]", ...args);
	};

	// State tracking to avoid duplicate notifications
	let currentState: "idle" | "busy" = "idle";

	async function notify(eventType: string): Promise<void> {
		const params = new URLSearchParams({
			paneId,
			tabId,
			workspaceId,
			eventType,
			env,
			version: hookVersion,
		});
		const url = `http://127.0.0.1:${port}/hook/complete?${params}`;
		log("notify", eventType, "url", url);
		try {
			await fetch(url, {
				signal: AbortSignal.timeout(2000),
			});
			log("sent", eventType);
		} catch (err) {
			log("failed", eventType, err);
		}
	}

	async function transitionBusy(): Promise<void> {
		if (currentState === "idle") {
			currentState = "busy";
			await notify("Start");
		}
	}

	async function transitionIdle(): Promise<void> {
		if (currentState === "busy") {
			currentState = "idle";
			await notify("Stop");
		}
	}

	// Agent starts processing a user message
	pi.on("agent_start", async () => {
		await transitionBusy();
	});

	// Agent finishes — waiting for next user input
	pi.on("agent_end", async () => {
		await transitionIdle();
	});

	// Tool execution keeps the busy state alive (prevents false idle
	// during multi-tool turns where agent_end hasn't fired yet)
	pi.on("tool_call", async () => {
		await transitionBusy();
	});
}

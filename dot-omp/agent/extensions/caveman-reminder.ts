/**
 * Caveman-lite reminder extension for Oh My Pi.
 *
 * Mirrors the Claude Code UserPromptSubmit hook in
 * dot-claude/hooks/caveman-reminder.sh. Appends a system-prompt
 * suffix every turn so the agent stays in caveman lite mode per
 * ~/.claude/CLAUDE.md (which OMP does not auto-read).
 *
 * Idempotent: skips if the reminder is already present in the
 * incoming system prompt (e.g. another extension already added it).
 */
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

const REMINDER =
	'\n\nUse skill://caveman:caveman lite mode for this response ' +
	'(per ~/.claude/CLAUDE.md). Disable only on "stop caveman" / "normal mode".';

const SENTINEL = "skill://caveman:caveman lite mode";

export default function cavemanReminder(pi: ExtensionAPI) {
	pi.setLabel("Caveman Lite Reminder");

	pi.on("before_agent_start", async (event) => {
		const joined = event.systemPrompt.join("\n");
		if (joined.includes(SENTINEL)) return;
		return { systemPrompt: [...event.systemPrompt, REMINDER.trim()] };
	});
}

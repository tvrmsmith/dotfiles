// Starts the next wave of the chain, detached, when this wave dispatched any
// slice. It carries the chain's tried list and names this run as `previous`,
// which is the link wave-status follows. Prints {next_run, reason}; next_run
// is empty when the chain ends here.
//
// Reaches Archon through ARCHON_CLI_COMMAND, the CLI the engine hands every
// script node, so `bun test` can point it at a stub. The run's own checkout is
// the working directory, which is the target repository the wave was started
// from.

function refuse(reason: string): never {
  console.error(`implement-in-waves next: ${reason}`);
  process.exit(1);
}

const wave = JSON.parse(process.env.INPUTS_WAVE || "[]") as string[];
if (wave.length === 0) {
  console.log(JSON.stringify({ next_run: "", reason: "this wave found no new ready child, so the chain ends" }));
} else {
  const runId = process.env.WORKFLOW_ID ?? "";
  if (runId === "") refuse("WORKFLOW_ID is unset, so the next wave could not name this one");

  let cli: unknown;
  try {
    cli = JSON.parse(process.env.ARCHON_CLI_COMMAND ?? "");
  } catch {
    refuse("ARCHON_CLI_COMMAND is not a JSON command line");
  }
  if (!Array.isArray(cli) || cli.length === 0) refuse("ARCHON_CLI_COMMAND is empty");

  const input = (name: string, value: string) => ["--input", `${name}=${value}`];
  const launch = Bun.spawnSync(
    [
      ...(cli as string[]),
      "workflow", "run", "implement-in-waves", "--detach", "--json", "--cwd", process.cwd(),
      ...input("parent", process.env.INPUTS_PARENT ?? ""),
      ...input("beads_dir", process.env.INPUTS_BEADS_DIR ?? ""),
      ...input("max_slices", process.env.INPUTS_MAX_SLICES || "0"),
      ...input("tried", process.env.INPUTS_CHAIN || "[]"),
      ...input("previous", runId),
    ],
    { stderr: "pipe" },
  );
  if (launch.exitCode !== 0) {
    refuse(`starting the next wave exited ${launch.exitCode}: ${launch.stderr.toString().trim()}`);
  }

  let ack: { runId?: unknown } = {};
  try {
    ack = JSON.parse(launch.stdout.toString());
  } catch {
    refuse(`the next wave started but its acknowledgement is not JSON: ${launch.stdout.toString().trim()}`);
  }
  if (typeof ack.runId !== "string" || ack.runId === "") {
    refuse("the next wave's acknowledgement names no runId");
  }
  console.log(JSON.stringify({ next_run: ack.runId, reason: `this wave dispatched ${wave.length}, so the next wave looks for more` }));
}

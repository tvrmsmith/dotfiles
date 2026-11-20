// Prototype: starts implement-in-waves on the new epic, detached, and prints
// {wave_run, status}. Same launch as implement-in-waves' next.ts.

function refuse(reason: string): never {
  console.error(`plan-epic handoff: ${reason}`);
  process.exit(1);
}

const epic = process.env.INPUTS_EPIC ?? "";
const beadsDir = process.env.INPUTS_BEADS_DIR ?? "";
if (epic === "" || beadsDir === "") refuse("epic or beads_dir is empty");

const cli = JSON.parse(process.env.ARCHON_CLI_COMMAND ?? "[]") as string[];
if (cli.length === 0) refuse("ARCHON_CLI_COMMAND is empty");

const launch = Bun.spawnSync(
  [
    ...cli,
    "workflow", "run", "implement-in-waves", "--detach", "--json", "--cwd", process.cwd(),
    "--input", `parent=${epic}`,
    "--input", `beads_dir=${beadsDir}`,
  ],
  { stderr: "pipe" },
);
if (launch.exitCode !== 0) refuse(`launch exited ${launch.exitCode}: ${launch.stderr.toString().trim()}`);
const ack = JSON.parse(launch.stdout.toString()) as { runId?: string };
if (!ack.runId) refuse("the launch acknowledgement names no runId");
console.log(JSON.stringify({ wave_run: ack.runId, status: `wave-status ${ack.runId}` }));

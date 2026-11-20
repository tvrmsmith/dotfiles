// Prototype: after the end gate says re-dispatch, starts another wave with the
// chosen beads cleared from the chain's tried list. The text names bead ids;
// empty means every open, unclaimed child close-parent reported.

function refuse(reason: string): never {
  console.error(`implement-in-waves redispatch: ${reason}`);
  process.exit(1);
}

const chain = JSON.parse(process.env.INPUTS_CHAIN || "[]") as string[];
const open = JSON.parse(process.env.INPUTS_OPEN || "[]") as Array<{ id: string; status: string; assignee: string }>;
const named = (process.env.INPUTS_TEXT ?? "").split(/[\s,]+/).filter((word) => word !== "");
const chosen = named.length > 0 ? named : open.filter((b) => b.status === "open" && b.assignee === "").map((b) => b.id);
if (chosen.length === 0) refuse("nothing to re-dispatch: no ids named and no open, unclaimed child");

const cli = JSON.parse(process.env.ARCHON_CLI_COMMAND ?? "[]") as string[];
const launch = Bun.spawnSync(
  [
    ...cli,
    "workflow", "run", "implement-in-waves", "--detach", "--json", "--cwd", process.cwd(),
    "--input", `parent=${process.env.INPUTS_PARENT ?? ""}`,
    "--input", `beads_dir=${process.env.INPUTS_BEADS_DIR ?? ""}`,
    "--input", `max_slices=${process.env.INPUTS_MAX_SLICES || "0"}`,
    "--input", `tried=${JSON.stringify(chain.filter((id) => !chosen.includes(id)))}`,
    "--input", `previous=${process.env.WORKFLOW_ID ?? ""}`,
  ],
  { stderr: "pipe" },
);
if (launch.exitCode !== 0) refuse(`launch exited ${launch.exitCode}: ${launch.stderr.toString().trim()}`);
const ack = JSON.parse(launch.stdout.toString()) as { runId?: string };
if (!ack.runId) refuse("the launch acknowledgement names no runId");
console.log(JSON.stringify({ next_run: ack.runId, redispatched: chosen }));

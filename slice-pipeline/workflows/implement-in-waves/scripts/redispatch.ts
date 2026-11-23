// Runs when the end gate chooses re-dispatch. Starts a new wave of this chain,
// detached, with the chosen beads cleared from the chain's tried list, and
// names this run as `previous` so wave-status follows the chain into it. That
// wave starts at ready, so it passes the seam gate again. Prints
// {next_run, redispatched}.
//
// The gate's text names the beads, separated by spaces or commas. Empty text
// chooses every open, unclaimed direct child. The children are read from bd
// now, not from close-parent's list, so a bead the engineer unclaimed while
// the gate was open counts as unclaimed. A named bead that is not an open
// direct child, or is still claimed, fails the node before anything starts:
// ready never offers a claimed bead, so the new wave would find nothing.
//
// Reads INPUTS_* directly so `bun test` can run it with stub `bd` and
// `archon` on PATH.

function refuse(reason: string): never {
  console.error(`implement-in-waves redispatch: ${reason}`);
  process.exit(1);
}

const parent = process.env.INPUTS_PARENT ?? "";
const beadsDir = process.env.INPUTS_BEADS_DIR ?? "";
if (parent === "") refuse("parent is empty");
if (beadsDir === "") refuse("beads_dir is empty");

let chain: unknown;
try {
  chain = JSON.parse(process.env.INPUTS_CHAIN || "[]");
} catch {
  refuse(`chain is not JSON: ${process.env.INPUTS_CHAIN}`);
}
if (!Array.isArray(chain) || !chain.every((id) => typeof id === "string")) {
  refuse(`chain must be a JSON array of bead ids, not ${process.env.INPUTS_CHAIN}`);
}
const tried = chain as string[];

// bd list without --all lists every child not closed. --parent matches every
// descendant, so the parent field keeps this to direct children.
const list = Bun.spawnSync(["bd", "list", "--parent", parent, "--json", "--limit", "0"], {
  env: { ...process.env, BEADS_DIR: beadsDir },
  stderr: "pipe",
});
if (list.exitCode !== 0) refuse(`bd list exited ${list.exitCode}: ${list.stderr.toString().trim()}`);
let listed: unknown;
try {
  listed = JSON.parse(list.stdout.toString() || "[]");
} catch {
  refuse("bd list printed something other than JSON");
}
if (!Array.isArray(listed)) refuse("bd list printed JSON that is not a list");
const open = new Map(
  (listed as Array<{ id?: unknown; parent?: unknown; status?: unknown; assignee?: unknown }>)
    .filter((bead) => bead.parent === parent && typeof bead.id === "string" && bead.status !== "closed")
    .map((bead) => [bead.id as string, { status: String(bead.status), assignee: String(bead.assignee ?? "") }]),
);

const named = [...new Set((process.env.INPUTS_TEXT ?? "").split(/[\s,]+/).filter((word) => word !== ""))];
let chosen: string[];
if (named.length > 0) {
  const unknown = named.filter((id) => !open.has(id));
  if (unknown.length > 0) refuse(`not an open child of ${parent}: ${unknown.join(", ")}`);
  const claimed = named.filter((id) => open.get(id)!.assignee !== "");
  if (claimed.length > 0) {
    refuse(`still claimed, so no wave would offer it: ${claimed.join(", ")}; unclaim with BEADS_DIR=${beadsDir} bd unclaim <id>`);
  }
  chosen = named;
} else {
  chosen = [...open].filter(([, bead]) => bead.status === "open" && bead.assignee === "").map(([id]) => id);
  if (chosen.length === 0) refuse(`nothing to re-dispatch: ${parent} has no open, unclaimed child`);
}

const runId = process.env.WORKFLOW_ID ?? "";
if (runId === "") refuse("WORKFLOW_ID is unset, so the new wave could not name this one");
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
    ...input("parent", parent),
    ...input("beads_dir", beadsDir),
    ...input("max_slices", process.env.INPUTS_MAX_SLICES || "0"),
    ...input("tried", JSON.stringify(tried.filter((id) => !chosen.includes(id)))),
    ...input("previous", runId),
  ],
  { stderr: "pipe" },
);
if (launch.exitCode !== 0) refuse(`starting the new wave exited ${launch.exitCode}: ${launch.stderr.toString().trim()}`);

let ack: { runId?: unknown } = {};
try {
  ack = JSON.parse(launch.stdout.toString());
} catch {
  refuse(`the new wave started but its acknowledgement is not JSON: ${launch.stdout.toString().trim()}`);
}
if (typeof ack.runId !== "string" || ack.runId === "") refuse("the new wave's acknowledgement names no runId");
console.log(JSON.stringify({ next_run: ack.runId, redispatched: chosen }));

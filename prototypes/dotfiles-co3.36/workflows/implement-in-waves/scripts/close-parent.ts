// Runs on the chain's last wave, the one that found nothing new. Closes the
// parent bead when every direct child is closed, and otherwise leaves it open
// and names the children still open. Prints {closed, open, reason}, where
// `open` lists each remaining child as {id, status, assignee}.
//
// A chain also ends with children open: a bead a slice released is not tried
// again in the same chain, a failed review keeps its bead claimed, and a bead
// blocked behind either never becomes ready. So the end of the chain alone is
// no reason to close the parent.
//
// Reads INPUTS_* directly so `bun test` can run it with a stub `bd` on PATH.

function refuse(reason: string): never {
  console.error(`implement-in-waves close-parent: ${reason}`);
  process.exit(1);
}

const parent = process.env.INPUTS_PARENT ?? "";
const beadsDir = process.env.INPUTS_BEADS_DIR ?? "";
if (parent === "") refuse("parent is empty");
if (beadsDir === "") refuse("beads_dir is empty");
const env = { ...process.env, BEADS_DIR: beadsDir };

function bdJson(args: string[]): unknown {
  const bd = Bun.spawnSync(["bd", ...args], { env, stderr: "pipe" });
  if (bd.exitCode !== 0) refuse(`bd ${args[0]} exited ${bd.exitCode}: ${bd.stderr.toString().trim()}`);
  try {
    return JSON.parse(bd.stdout.toString() || "[]");
  } catch {
    refuse(`bd ${args[0]} printed something other than JSON`);
  }
}

interface Bead {
  id?: unknown;
  parent?: unknown;
  status?: unknown;
  assignee?: unknown;
}

const listed = bdJson(["list", "--parent", parent, "--all", "--json", "--limit", "0"]);
if (!Array.isArray(listed)) refuse("bd list printed JSON that is not a list");
const children = (listed as Bead[]).filter((bead) => bead.parent === parent);
const open = children
  .filter((bead) => bead.status !== "closed")
  .map((bead) => ({ id: String(bead.id), status: String(bead.status), assignee: String(bead.assignee ?? "") }));

if (open.length > 0) {
  const names = open.map((bead) => `${bead.id} (${bead.status})`).join(", ");
  console.log(JSON.stringify({ closed: false, open, reason: `parent ${parent} left open: ${names}` }));
} else {
  const shown = bdJson(["show", parent, "--json"]) as Bead[];
  if (shown[0]?.status === "closed") {
    console.log(JSON.stringify({ closed: true, open, reason: `parent ${parent} was already closed` }));
  } else {
    const runId = process.env.WORKFLOW_ID ?? "";
    // No --force: bd refuses a parent with an open child, which is the last
    // guard if a child opened between the list and this close.
    const close = Bun.spawnSync(
      ["bd", "close", parent, "--reason", `every child closed; closed by implement-in-waves run ${runId}`],
      { env, stderr: "pipe", stdout: "pipe" },
    );
    if (close.exitCode !== 0) refuse(`bd close ${parent} exited ${close.exitCode}: ${close.stderr.toString().trim()}`);
    console.log(JSON.stringify({ closed: true, open, reason: `parent ${parent} closed: all ${children.length} children are closed` }));
  }
}

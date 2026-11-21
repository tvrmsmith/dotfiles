// Lists the beads one wave dispatches: the parent's direct children that bd
// reports ready and unassigned, minus the beads earlier waves of this chain
// already tried and any child with an open child of its own, capped at
// max_slices. bd refuses to close a bead with an open child, so a slice of one
// would merge and then fail its close with the bead still claimed. Prints
// {beads, count}: the candidates the seam gate proposes from, and their
// count, which lets the workflow skip that gate on an empty wave. apply-seams
// adds the approved ones to the chain's tried list.
//
// Reads the workflow's inputs from INPUTS_* directly rather than through
// `archon:script`, so `bun test` can run it with a stub `bd` on PATH.

function refuse(reason: string): never {
  console.error(`implement-in-waves ready: ${reason}`);
  process.exit(1);
}

const parent = process.env.INPUTS_PARENT ?? "";
const beadsDir = process.env.INPUTS_BEADS_DIR ?? "";
if (parent === "") refuse("parent is empty");
if (beadsDir === "") refuse("beads_dir is empty");

const maxSlices = Number(process.env.INPUTS_MAX_SLICES || "0");
if (!Number.isInteger(maxSlices) || maxSlices < 0) {
  refuse(`max_slices must be a whole number of 0 or more, not ${process.env.INPUTS_MAX_SLICES}`);
}

let tried: unknown;
try {
  tried = JSON.parse(process.env.INPUTS_TRIED || "[]");
} catch {
  refuse(`tried is not JSON: ${process.env.INPUTS_TRIED}`);
}
if (!Array.isArray(tried) || !tried.every((id) => typeof id === "string")) {
  refuse(`tried must be a JSON array of bead ids, not ${process.env.INPUTS_TRIED}`);
}
const triedIds = tried as string[];

// --parent matches every descendant, so the parent field is what keeps the
// wave one level down. --limit 0 lifts bd's default cap of 100.
const bd = Bun.spawnSync(
  ["bd", "ready", "--parent", parent, "--unassigned", "--json", "--brief", "--limit", "0"],
  { env: { ...process.env, BEADS_DIR: beadsDir }, stderr: "pipe" },
);
if (bd.exitCode !== 0) {
  refuse(`bd ready exited ${bd.exitCode}: ${bd.stderr.toString().trim()}`);
}

let rows: unknown;
try {
  rows = JSON.parse(bd.stdout.toString() || "[]");
} catch {
  refuse("bd ready printed something other than JSON");
}
if (!Array.isArray(rows)) refuse("bd ready printed JSON that is not a list");

// bd list without --all lists every child not closed, which is what bd close
// counts as open.
function hasOpenChild(id: string): boolean {
  const list = Bun.spawnSync(["bd", "list", "--parent", id, "--json", "--limit", "0"], {
    env: { ...process.env, BEADS_DIR: beadsDir },
    stderr: "pipe",
  });
  if (list.exitCode !== 0) refuse(`bd list exited ${list.exitCode}: ${list.stderr.toString().trim()}`);
  let listed: unknown;
  try {
    listed = JSON.parse(list.stdout.toString() || "[]");
  } catch {
    refuse(`bd list --parent ${id} printed something other than JSON`);
  }
  if (!Array.isArray(listed)) refuse(`bd list --parent ${id} printed JSON that is not a list`);
  return (listed as Array<{ parent?: unknown }>).some((row) => row.parent === id);
}

const children = (rows as Array<{ id?: unknown; parent?: unknown }>)
  .filter((row) => row.parent === parent && typeof row.id === "string")
  .map((row) => row.id as string)
  .filter((id) => !triedIds.includes(id))
  .filter((id) => !hasOpenChild(id));
const beads = maxSlices === 0 ? children : children.slice(0, maxSlices);

console.log(JSON.stringify({ beads, count: beads.length }));

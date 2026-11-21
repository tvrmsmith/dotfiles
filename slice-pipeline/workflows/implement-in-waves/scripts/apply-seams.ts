// Settles one wave once its seam gate approves. Appends each dispatched bead's
// agreed seams to its notes, takes each not-this-epic bead out of the parent,
// and prints {beads, tried}: the wave to dispatch, and the chain's tried list
// with that wave added. A bead the engineer dropped is in neither, so the next
// wave offers it again. A moved-out bead has no parent, so no wave offers it.
//
// The proposal is the seam loop's output, or {} when an empty wave skipped the
// gate. Everything is checked before the first write: a proposal that names a
// bead ready did not offer, puts one bead in both lists, or dispatches a bead
// with no seams fails the node rather than dispatch something nobody approved.
//
// A resumed run reruns this node, so a bead whose notes already carry this
// run's seams is not written again.
//
// Reads INPUTS_* directly so `bun test` can run it with a stub `bd` on PATH.

function refuse(reason: string): never {
  console.error(`implement-in-waves apply-seams: ${reason}`);
  process.exit(1);
}

function parse<T>(name: string, fallback: string): T {
  const raw = process.env[name] || fallback;
  try {
    return JSON.parse(raw) as T;
  } catch {
    refuse(`${name} is not JSON: ${raw}`);
  }
}

const beadsDir = process.env.INPUTS_BEADS_DIR ?? "";
if (beadsDir === "") refuse("beads_dir is empty");
const env = { ...process.env, BEADS_DIR: beadsDir };

const candidates = parse<string[]>("INPUTS_CANDIDATES", "[]");
const tried = parse<string[]>("INPUTS_TRIED", "[]");
const proposal = parse<{ wave?: string[]; seams?: Array<{ id: string; seams: string }>; not_this_epic?: string[] }>(
  "INPUTS_PROPOSAL",
  "{}",
);
const wave = proposal.wave ?? [];
const moved = proposal.not_this_epic ?? [];
const seamsOf = new Map((proposal.seams ?? []).map(({ id, seams }) => [id, seams]));

for (const id of [...wave, ...moved]) {
  if (!candidates.includes(id)) refuse(`${id} is not a candidate ready offered this wave (${candidates.join(", ")})`);
}
for (const id of wave) {
  if (moved.includes(id)) refuse(`${id} is both in the wave and out of the epic`);
  if (!seamsOf.get(id)?.trim()) refuse(`the proposal has no seams for ${id}`);
}

function bd(args: string[]): string {
  const run = Bun.spawnSync(["bd", ...args], { env, stderr: "pipe", stdout: "pipe" });
  if (run.exitCode !== 0) refuse(`bd ${args[0]} ${args[1]} exited ${run.exitCode}: ${run.stderr.toString().trim()}`);
  return run.stdout.toString();
}

const header = `Seams agreed in implement-in-waves run ${process.env.WORKFLOW_ID ?? ""}:`;
for (const id of moved) bd(["update", id, "--parent", ""]);
for (const id of wave) {
  let notes = "";
  try {
    notes = String((JSON.parse(bd(["show", id, "--json"])) as Array<{ notes?: unknown }>)[0]?.notes ?? "");
  } catch {
    refuse(`bd show ${id} printed something other than JSON`);
  }
  if (!notes.includes(header)) bd(["update", id, "--append-notes", `${header}\n${seamsOf.get(id)}`]);
}

// Candidate order, so the slices' child indexes follow ready's order.
const beads = candidates.filter((id) => wave.includes(id));
console.log(JSON.stringify({ beads, tried: [...tried, ...beads] }));

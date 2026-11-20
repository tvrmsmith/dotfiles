// Prototype: applies an approved seam proposal. Appends each bead's seams to
// its notes, removes not-this-epic beads from the parent, and prints
// {beads, tried}: the wave to dispatch and the chain's tried list with it
// added. A dropped bead is in neither, so the next wave sees it again.

function refuse(reason: string): never {
  console.error(`implement-in-waves apply-seams: ${reason}`);
  process.exit(1);
}

const env = { ...process.env, BEADS_DIR: process.env.INPUTS_BEADS_DIR ?? "" };
const candidates = JSON.parse(process.env.INPUTS_CANDIDATES || "[]") as string[];
const tried = JSON.parse(process.env.INPUTS_TRIED || "[]") as string[];
const proposal = JSON.parse(process.env.INPUTS_PROPOSAL || "{}") as {
  wave?: string[];
  seams?: Array<{ id: string; seams: string }>;
  not_this_epic?: string[];
};

function bd(args: string[]) {
  const run = Bun.spawnSync(["bd", ...args], { env, stderr: "pipe", stdout: "pipe" });
  if (run.exitCode !== 0) refuse(`bd ${args.join(" ")} exited ${run.exitCode}: ${run.stderr.toString().trim()}`);
}

// Only beads `ready` offered: the agent cannot widen the wave.
const wave = (proposal.wave ?? []).filter((id) => candidates.includes(id));
for (const id of proposal.not_this_epic ?? []) {
  if (candidates.includes(id) && !wave.includes(id)) bd(["update", id, "--parent", ""]);
}
for (const { id, seams } of proposal.seams ?? []) {
  if (wave.includes(id)) bd(["update", id, "--append-notes", `Seams agreed for wave ${process.env.WORKFLOW_ID}:\n${seams}`]);
}
console.log(JSON.stringify({ beads: wave, tried: [...tried, ...wave] }));

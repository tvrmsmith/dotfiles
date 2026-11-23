// Drives implement-in-waves's scripts and wave-status as the engine and a
// person run them, with `bd` and `archon` replaced by stubs on PATH. Each stub
// appends its argv to a log and prints what the test told it to.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "..");
const READY = join(ROOT, "workflows/implement-in-waves/scripts/ready.ts");
const NEXT = join(ROOT, "workflows/implement-in-waves/scripts/next.ts");
const CLOSE_PARENT = join(ROOT, "workflows/implement-in-waves/scripts/close-parent.ts");
const APPLY_SEAMS = join(ROOT, "workflows/implement-in-waves/scripts/apply-seams.ts");
const REDISPATCH = join(ROOT, "workflows/implement-in-waves/scripts/redispatch.ts");
const WAVE_STATUS = join(ROOT, "bin/wave-status");
// Recorded from the live smoke: `archon workflow runs --all --json --verbose`,
// trimmed to the smoke's runs and to the fields wave-status reads, with the
// home directory respelled. Two chains: wv-2nc (A merged and B released in
// wave 1, C, which A unblocked, merged in wave 2, then an empty wave 3) and
// sm-cmj (A's close failed after its claim, B released).
const FINAL = join(import.meta.dir, "fixtures/wave/runs-final.json");
const MIDRUN = join(import.meta.dir, "fixtures/wave/runs-midrun.json");

let bin: string;

// A stub that logs `<BEADS_DIR>\t<argv>` and prints the file named by
// <NAME>_OUT, exiting with <NAME>_EXIT. <NAME>_OUT_<subcommand> and
// <NAME>_EXIT_<subcommand> (bd list, bd show, ...) win over those, and a file
// byArgs() wrote for the exact argv wins over both.
function stub(name: string) {
  const path = join(bin, name);
  const upper = name.toUpperCase();
  writeFileSync(
    path,
    `#!/bin/bash
printf '%s\\t%s\\n' "\${BEADS_DIR:-}" "$*" >> "${bin}/${name}.log"
out="${upper}_OUT_\${1:-}"; out="\${!out:-\${${upper}_OUT:-}}"
exact="${bin}/${name}.by-args/$(printf '%s' "$*" | tr ' /' '__')"; [ -f "$exact" ] && out="$exact"
code="${upper}_EXIT_\${1:-}"; code="\${!code:-\${${upper}_EXIT:-0}}"
[ -n "$out" ] && cat "$out"
exit "$code"
`,
  );
  chmodSync(path, 0o755);
}

function output(name: string, text: string): string {
  const path = join(bin, `${name}.out`);
  writeFileSync(path, text);
  return path;
}

// Makes stub `name` print `text` when called with exactly `args`.
function byArgs(name: string, args: string, text: string) {
  mkdirSync(join(bin, `${name}.by-args`), { recursive: true });
  writeFileSync(join(bin, `${name}.by-args`, args.replace(/[ /]/g, "_")), text);
}

function calls(name: string): string[] {
  try {
    return readFileSync(join(bin, `${name}.log`), "utf8").trimEnd().split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

function run(cmd: string[], env: Record<string, string>) {
  const result = Bun.spawnSync(cmd, {
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, ...env },
    cwd: bin,
    stderr: "pipe",
  });
  return {
    code: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
    json: () => JSON.parse(result.stdout.toString()),
  };
}

beforeEach(() => {
  bin = realpathSync(mkdtempSync(join(tmpdir(), "implement-in-waves-test.")));
  stub("bd");
  stub("archon");
});

afterEach(() => rmSync(bin, { recursive: true, force: true }));

const child = (id: string, parent = "p") => ({ id, parent, status: "open" });

describe("ready", () => {
  const inputs = (extra: Record<string, string> = {}) => ({
    INPUTS_PARENT: "p",
    INPUTS_BEADS_DIR: "/tracker/.beads",
    INPUTS_MAX_SLICES: "0",
    INPUTS_TRIED: "[]",
    ...extra,
  });

  test("asks bd for the parent's ready, unassigned beads in the tracker the wave names", () => {
    const r = run(["bun", READY], { ...inputs(), BD_OUT: output("bd", "[]") });
    expect(r.code).toBe(0);
    expect(calls("bd")).toEqual(["/tracker/.beads\tready --parent p --unassigned --json --brief --limit 0"]);
  });

  test("dispatches direct children only, never a grandchild", () => {
    const rows = [child("p.1"), child("p.1.1", "p.1"), child("p.2")];
    const r = run(["bun", READY], {
      ...inputs(),
      BD_OUT_ready: output("bd-ready", JSON.stringify(rows)),
      BD_OUT_list: output("bd-list", "[]"),
    });
    expect(r.json()).toEqual({ beads: ["p.1", "p.2"], count: 2 });
  });

  // bd refuses to close a bead with an open child, so a slice of one would
  // merge and then fail its close with the bead still claimed.
  test("skips a child that has open children of its own, without marking it tried", () => {
    const rows = [child("p.1"), child("p.1.1", "p.1"), child("p.2")];
    byArgs("bd", "list --parent p.1 --json --limit 0", JSON.stringify([{ id: "p.1.1", parent: "p.1", status: "deferred" }]));
    const r = run(["bun", READY], {
      ...inputs(),
      BD_OUT_ready: output("bd-ready", JSON.stringify(rows)),
      BD_OUT_list: output("bd-list", "[]"),
    });
    expect(r.code).toBe(0);
    expect(r.json()).toEqual({ beads: ["p.2"], count: 1 });
    expect(calls("bd")).toContain("/tracker/.beads\tlist --parent p.1 --json --limit 0");
  });

  test("caps the wave after skipping, so a skipped child does not take a slot", () => {
    const rows = [child("p.1"), child("p.2"), child("p.3")];
    byArgs("bd", "list --parent p.1 --json --limit 0", JSON.stringify([child("p.1.1", "p.1")]));
    const r = run(["bun", READY], {
      ...inputs({ INPUTS_MAX_SLICES: "1" }),
      BD_OUT_ready: output("bd-ready", JSON.stringify(rows)),
      BD_OUT_list: output("bd-list", "[]"),
    });
    expect(r.json()).toEqual({ beads: ["p.2"], count: 1 });
  });

  test("fails the node when bd cannot list a child's children, rather than dispatching it blind", () => {
    const r = run(["bun", READY], {
      ...inputs(),
      BD_OUT_ready: output("bd-ready", JSON.stringify([child("p.1")])),
      BD_EXIT_list: "2",
    });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("bd list exited 2");
  });

  test("skips a bead an earlier wave of the chain tried", () => {
    const rows = [child("p.1"), child("p.2"), child("p.3")];
    const r = run(["bun", READY], {
      ...inputs({ INPUTS_TRIED: '["p.1"]' }),
      BD_OUT: output("bd", JSON.stringify(rows)),
    });
    expect(r.json()).toEqual({ beads: ["p.2", "p.3"], count: 2 });
  });

  test("max_slices caps the wave and leaves the rest for later waves", () => {
    const rows = [child("p.1"), child("p.2"), child("p.3")];
    const r = run(["bun", READY], {
      ...inputs({ INPUTS_MAX_SLICES: "2" }),
      BD_OUT: output("bd", JSON.stringify(rows)),
    });
    expect(r.json()).toEqual({ beads: ["p.1", "p.2"], count: 2 });
  });

  test("an empty frontier is an empty wave, not a failure", () => {
    const r = run(["bun", READY], { ...inputs(), BD_OUT: output("bd", "[]") });
    expect(r.code).toBe(0);
    expect(r.json()).toEqual({ beads: [], count: 0 });
  });

  test("fails the node when bd fails, rather than dispatching nothing as if all were done", () => {
    const r = run(["bun", READY], { ...inputs(), BD_EXIT: "3" });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("bd ready exited 3");
  });

  test.each([
    ["a negative max_slices", { INPUTS_MAX_SLICES: "-1" }, "max_slices"],
    ["a fractional max_slices", { INPUTS_MAX_SLICES: "1.5" }, "max_slices"],
    ["a tried list that is not JSON", { INPUTS_TRIED: "p.1" }, "tried is not JSON"],
    ["a tried list of non-strings", { INPUTS_TRIED: "[1]" }, "tried must be"],
  ])("refuses %s before asking bd", (_name, extra, message) => {
    const r = run(["bun", READY], inputs(extra));
    expect(r.code).toBe(1);
    expect(r.stderr).toContain(message);
    expect(calls("bd")).toEqual([]);
  });
});

describe("next", () => {
  const inputs = (wave: string[], chain: string[]) => ({
    INPUTS_PARENT: "p",
    INPUTS_BEADS_DIR: "/tracker/.beads",
    INPUTS_MAX_SLICES: "2",
    INPUTS_WAVE: JSON.stringify(wave),
    INPUTS_CHAIN: JSON.stringify(chain),
    WORKFLOW_ID: "wave-1-run",
    ARCHON_CLI_COMMAND: JSON.stringify(["archon"]),
  });

  test("ends the chain on an empty wave without starting anything", () => {
    const r = run(["bun", NEXT], inputs([], ["p.1"]));
    expect(r.code).toBe(0);
    expect(r.json().next_run).toBe("");
    expect(calls("archon")).toEqual([]);
  });

  test("starts the next wave detached, in this checkout, carrying the chain and naming this run", () => {
    const r = run(["bun", NEXT], {
      ...inputs(["p.2"], ["p.1", "p.2"]),
      ARCHON_OUT: output("archon", '{"runId":"wave-2-run","transcriptPath":"/t","logPath":"/l"}'),
    });
    expect(r.code).toBe(0);
    expect(r.json().next_run).toBe("wave-2-run");
    const [, argv] = calls("archon")[0].split("\t");
    expect(argv).toContain("workflow run implement-in-waves --detach --json --cwd ");
    expect(argv).toContain(`--cwd ${bin}`);
    expect(argv).toContain(
      '--input parent=p --input beads_dir=/tracker/.beads --input max_slices=2 --input tried=["p.1","p.2"] --input previous=wave-1-run',
    );
  });

  test("fails the node when the next wave cannot start, so the chain's end is visible", () => {
    const r = run(["bun", NEXT], { ...inputs(["p.2"], ["p.2"]), ARCHON_EXIT: "1" });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("starting the next wave exited 1");
  });

  test("fails the node when the launch acknowledges no run", () => {
    const r = run(["bun", NEXT], { ...inputs(["p.2"], ["p.2"]), ARCHON_OUT: output("archon", "{}") });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("names no runId");
  });
});

describe("apply-seams", () => {
  const seams = (id: string) => ({ id, seams: `seams for ${id}` });
  const inputs = (proposal: object | null, extra: Record<string, string> = {}) => ({
    INPUTS_BEADS_DIR: "/tracker/.beads",
    INPUTS_TRIED: '["p.1"]',
    INPUTS_CANDIDATES: '["p.2","p.3","p.4"]',
    INPUTS_PROPOSAL: proposal === null ? "{}" : JSON.stringify(proposal),
    WORKFLOW_ID: "wave-run",
    BD_OUT_show: output("bd-show", JSON.stringify([{ id: "x", notes: "" }])),
    ...extra,
  });
  const writes = () => calls("bd").filter((line) => line.includes("\tupdate "));
  const header = "Seams agreed in implement-in-waves run wave-run:";

  test("appends each dispatched bead's seams to its notes, in the tracker the wave names", () => {
    const r = run(["bun", APPLY_SEAMS], inputs({ wave: ["p.2", "p.3"], seams: [seams("p.2"), seams("p.3")], not_this_epic: [] }));
    expect(r.code).toBe(0);
    // The notes span lines, so the log is read whole rather than per call.
    expect(writes()).toEqual([
      `/tracker/.beads\tupdate p.2 --append-notes ${header}`,
      `/tracker/.beads\tupdate p.3 --append-notes ${header}`,
    ]);
    const log = readFileSync(join(bin, "bd.log"), "utf8");
    expect(log).toContain(`update p.2 --append-notes ${header}\nseams for p.2\n`);
    expect(log).toContain(`update p.3 --append-notes ${header}\nseams for p.3\n`);
  });

  test("settles the wave and adds it to the chain's tried list, leaving a dropped bead in neither", () => {
    const r = run(["bun", APPLY_SEAMS], inputs({ wave: ["p.2"], seams: [seams("p.2")], not_this_epic: [] }));
    expect(r.json()).toEqual({ beads: ["p.2"], tried: ["p.1", "p.2"] });
  });

  test("takes a not-this-epic bead out of the epic and out of the wave", () => {
    const r = run(["bun", APPLY_SEAMS], inputs({ wave: ["p.2"], seams: [seams("p.2")], not_this_epic: ["p.4"] }));
    expect(r.code).toBe(0);
    expect(r.json()).toEqual({ beads: ["p.2"], tried: ["p.1", "p.2"] });
    expect(writes()[0]).toBe("/tracker/.beads\tupdate p.4 --parent ");
  });

  test("an empty wave, whose seam gate was skipped, settles to nothing and writes nothing", () => {
    const r = run(["bun", APPLY_SEAMS], inputs(null, { INPUTS_CANDIDATES: "[]" }));
    expect(r.code).toBe(0);
    expect(r.json()).toEqual({ beads: [], tried: ["p.1"] });
    expect(calls("bd")).toEqual([]);
  });

  test("a rerun does not append the same run's seams twice", () => {
    const r = run(["bun", APPLY_SEAMS], inputs(
      { wave: ["p.2"], seams: [seams("p.2")], not_this_epic: [] },
      { BD_OUT_show: output("bd-show-seamed", JSON.stringify([{ id: "p.2", notes: `earlier\n${header}\nseams for p.2` }])) },
    ));
    expect(r.code).toBe(0);
    expect(r.json().beads).toEqual(["p.2"]);
    expect(writes()).toEqual([]);
  });

  test.each([
    ["a bead ready did not offer", { wave: ["p.2", "q.9"], seams: [seams("p.2"), seams("q.9")], not_this_epic: [] }, "q.9 is not a candidate"],
    ["a bead both dispatched and out of the epic", { wave: ["p.2"], seams: [seams("p.2")], not_this_epic: ["p.2"] }, "p.2 is both"],
    ["a dispatched bead with no seams", { wave: ["p.2", "p.3"], seams: [seams("p.2")], not_this_epic: [] }, "no seams for p.3"],
    ["a not-this-epic bead ready did not offer", { wave: [], seams: [], not_this_epic: ["q.9"] }, "q.9 is not a candidate"],
  ])("refuses %s before writing anything", (_name, proposal, message) => {
    const r = run(["bun", APPLY_SEAMS], inputs(proposal));
    expect(r.code).toBe(1);
    expect(r.stderr).toContain(message);
    expect(writes()).toEqual([]);
  });

  test("fails the node when bd refuses a write", () => {
    const r = run(["bun", APPLY_SEAMS], inputs({ wave: ["p.2"], seams: [seams("p.2")], not_this_epic: [] }, { BD_EXIT_update: "1" }));
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("bd update p.2 exited 1");
  });
});

describe("close-parent", () => {
  const inputs = { INPUTS_PARENT: "p", INPUTS_BEADS_DIR: "/tracker/.beads", WORKFLOW_ID: "last-wave" };
  const bead = (id: string, status: string, parent = "p", assignee = "") => ({ id, status, parent, assignee });
  const children = (...rows: object[]) => ({ BD_OUT_list: output("bd-list", JSON.stringify(rows)) });
  const parentIs = (status: string) => ({ BD_OUT_show: output("bd-show", JSON.stringify([bead("p", status, "")])) });

  test("closes the parent once every direct child is closed", () => {
    const r = run(["bun", CLOSE_PARENT], { ...inputs, ...children(bead("p.1", "closed"), bead("p.2", "closed")), ...parentIs("open") });
    expect(r.code).toBe(0);
    expect(r.json()).toEqual({ closed: true, open: [], reason: "parent p closed: all 2 children are closed" });
    expect(calls("bd")).toEqual([
      "/tracker/.beads\tlist --parent p --all --json --limit 0",
      "/tracker/.beads\tshow p --json",
      "/tracker/.beads\tclose p --reason every child closed; closed by implement-in-waves run last-wave",
    ]);
  });

  test("leaves the parent open and names every child still open", () => {
    const r = run(["bun", CLOSE_PARENT], {
      ...inputs,
      ...children(bead("p.1", "closed"), bead("p.2", "open"), bead("p.3", "in_progress", "p", "someone")),
    });
    expect(r.code).toBe(0);
    expect(r.json()).toEqual({
      closed: false,
      open: [{ id: "p.2", status: "open", assignee: "" }, { id: "p.3", status: "in_progress", assignee: "someone" }],
      reason: "parent p left open: p.2 (open), p.3 (in_progress)",
    });
    expect(calls("bd").some((line) => line.includes("\tclose "))).toBe(false);
  });

  test("judges direct children only", () => {
    const r = run(["bun", CLOSE_PARENT], {
      ...inputs, ...children(bead("p.1", "closed"), bead("p.1.1", "open", "p.1")), ...parentIs("open"),
    });
    expect(r.json().closed).toBe(true);
  });

  test("does not close a parent already closed", () => {
    const r = run(["bun", CLOSE_PARENT], { ...inputs, ...children(bead("p.1", "closed")), ...parentIs("closed") });
    expect(r.json()).toEqual({ closed: true, open: [], reason: "parent p was already closed" });
    expect(calls("bd").some((line) => line.includes("\tclose "))).toBe(false);
  });

  test("fails the node when bd refuses the close", () => {
    const r = run(["bun", CLOSE_PARENT], { ...inputs, ...children(bead("p.1", "closed")), ...parentIs("open"), BD_EXIT_close: "1" });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("bd close p exited 1");
  });

  test("fails the node when bd cannot list the children, rather than closing blind", () => {
    const r = run(["bun", CLOSE_PARENT], { ...inputs, BD_EXIT_list: "2" });
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("bd list exited 2");
    expect(calls("bd")).toHaveLength(1);
  });
});

describe("redispatch", () => {
  const bead = (id: string, status = "open", assignee = "", parent = "p") => ({ id, parent, status, assignee });
  const inputs = (text: string, children: object[], extra: Record<string, string> = {}) => ({
    INPUTS_PARENT: "p",
    INPUTS_BEADS_DIR: "/tracker/.beads",
    INPUTS_MAX_SLICES: "2",
    INPUTS_CHAIN: '["p.1","p.2","p.3"]',
    INPUTS_TEXT: text,
    WORKFLOW_ID: "last-wave",
    ARCHON_CLI_COMMAND: JSON.stringify(["archon"]),
    BD_OUT_list: output("bd-list", JSON.stringify(children)),
    ARCHON_OUT: output("archon", '{"runId":"new-wave"}'),
    ...extra,
  });
  const launched = () => calls("archon").map((line) => line.split("\t")[1]);

  test("starts a new wave of the chain with the named beads cleared from the tried list", () => {
    const r = run(["bun", REDISPATCH], inputs("p.2", [bead("p.2"), bead("p.3")]));
    expect(r.code).toBe(0);
    expect(r.json()).toEqual({ next_run: "new-wave", redispatched: ["p.2"] });
    expect(calls("bd")).toEqual(["/tracker/.beads\tlist --parent p --json --limit 0"]);
    expect(launched()).toHaveLength(1);
    expect(launched()[0]).toContain(`workflow run implement-in-waves --detach --json --cwd ${bin}`);
    expect(launched()[0]).toContain(
      '--input parent=p --input beads_dir=/tracker/.beads --input max_slices=2 --input tried=["p.1","p.3"] --input previous=last-wave',
    );
  });

  test("reads several names separated by commas or spaces, once each", () => {
    const r = run(["bun", REDISPATCH], inputs(" p.2, p.3\np.2 ", [bead("p.2"), bead("p.3")]));
    expect(r.json().redispatched).toEqual(["p.2", "p.3"]);
    expect(launched()[0]).toContain('--input tried=["p.1"]');
  });

  test("empty text re-dispatches every open, unclaimed direct child and nothing else", () => {
    const r = run(["bun", REDISPATCH], inputs("", [
      bead("p.2"), bead("p.3", "in_progress", "someone"), bead("p.4", "blocked"), bead("p.5"), bead("p.5.1", "open", "", "p.5"),
    ]));
    expect(r.code).toBe(0);
    expect(r.json().redispatched).toEqual(["p.2", "p.5"]);
    expect(launched()[0]).toContain('--input tried=["p.1","p.3"]');
  });

  test("a bead unclaimed while the gate was open counts as unclaimed, since bd is read now", () => {
    const r = run(["bun", REDISPATCH], inputs("p.3", [bead("p.3")]));
    expect(r.code).toBe(0);
    expect(r.json().redispatched).toEqual(["p.3"]);
  });

  test.each([
    ["a name that is not an open child", "p.2 p.9", [bead("p.2")], "not an open child of p: p.9"],
    ["a grandchild", "p.2.1", [bead("p.2.1", "open", "", "p.2")], "not an open child of p: p.2.1"],
    ["a claimed bead", "p.3", [bead("p.3", "in_progress", "someone")], "still claimed, so no wave would offer it: p.3"],
    ["empty text with no open, unclaimed child", "", [bead("p.3", "in_progress", "someone")], "nothing to re-dispatch"],
    ["a chain that is not JSON", "p.2", [bead("p.2")], "chain is not JSON"],
  ])("refuses %s before starting anything", (name, text, children, message) => {
    const extra = name.startsWith("a chain") ? { INPUTS_CHAIN: "p.1" } : {};
    const r = run(["bun", REDISPATCH], inputs(text, children, extra));
    expect(r.code).toBe(1);
    expect(r.stderr).toContain(message);
    expect(calls("archon")).toEqual([]);
  });

  test("fails the node when bd cannot list the children", () => {
    const r = run(["bun", REDISPATCH], inputs("p.2", [], { BD_EXIT_list: "2" }));
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("bd list exited 2");
    expect(calls("archon")).toEqual([]);
  });

  test("fails the node when the new wave cannot start", () => {
    const r = run(["bun", REDISPATCH], inputs("p.2", [bead("p.2")], { ARCHON_EXIT: "1" }));
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("starting the new wave exited 1");
  });

  test("fails the node when the launch acknowledges no run", () => {
    const r = run(["bun", REDISPATCH], inputs("p.2", [bead("p.2")], { ARCHON_OUT: output("archon-empty", "{}") }));
    expect(r.code).toBe(1);
    expect(r.stderr).toContain("names no runId");
  });
});

// The fixtures stub both scripts away and the tests above hand-set their
// inputs, so both stay green if the workflow and a script drift apart. This
// reads what implement-in-waves.yaml declares about each script node and holds the
// real script to it: every INPUTS_* name the script reads is a workflow input
// or one of the node's `with:` names, and its real output carries exactly the
// declared required fields.
describe("implement-in-waves.yaml wiring", () => {
  const workflow = Bun.YAML.parse(readFileSync(join(ROOT, "workflows/implement-in-waves/implement-in-waves.yaml"), "utf8")) as any;
  const node = (id: string) => workflow.nodes.find((n: any) => n.id === id);
  const envName = (name: string) => `INPUTS_${name.toUpperCase()}`;

  test.each([["ready", READY], ["apply-seams", APPLY_SEAMS], ["next", NEXT], ["close-parent", CLOSE_PARENT], ["redispatch", REDISPATCH]])("every input %s reads is bound", (id, path) => {
    const bound = new Set([...Object.keys(workflow.inputs), ...Object.keys(node(id).with ?? {})].map(envName));
    const read = [...readFileSync(path, "utf8").matchAll(/INPUTS_[A-Z_]+/g)].map((m) => m[0]);
    expect(read.length).toBeGreaterThan(0);
    expect(read.filter((name) => !bound.has(name))).toEqual([]);
  });

  test("ready's output is what ready declares, and what slices and next read from it", () => {
    const r = run(["bun", READY], {
      INPUTS_PARENT: "p", INPUTS_BEADS_DIR: "/b", INPUTS_MAX_SLICES: "0", INPUTS_TRIED: "[]",
      BD_OUT: output("bd", JSON.stringify([child("p.1")])),
    });
    expect(Object.keys(r.json()).sort()).toEqual([...node("ready").output_format.required].sort());
    expect(node("seams").when).toBe("$ready.output.count > 0");
    expect(node("apply-seams").with.candidates).toBe("$ready.output.beads");
  });

  test("apply-seams reads the proposal the seam gate approved, and slices and next dispatch only its settled wave", () => {
    const group = node("seams").loop_group;
    const propose = group.nodes.find((n: any) => n.id === "propose");
    const gate = group.nodes.find((n: any) => n.id === "seam-gate");
    expect(gate.depends_on).toEqual(["propose"]);
    expect(gate.wait.options.map((o: any) => o.id)).toEqual(["approve", "revise"]);
    expect(group.until_bash).toContain("$seam-gate.output.decision");
    expect(propose.output_format.required).toEqual(expect.arrayContaining(["wave", "seams", "not_this_epic"]));
    expect(node("apply-seams").with.proposal).toEqual({ from: "$seams.output", if_skipped: "{}" });

    const r = run(["bun", APPLY_SEAMS], {
      INPUTS_BEADS_DIR: "/b", INPUTS_TRIED: "[]", INPUTS_CANDIDATES: '["p.1"]',
      INPUTS_PROPOSAL: JSON.stringify({ wave: ["p.1"], seams: [{ id: "p.1", seams: "s" }], not_this_epic: [] }),
      WORKFLOW_ID: "w", BD_OUT_show: output("bd-show", '[{"notes":""}]'),
    });
    expect(Object.keys(r.json()).sort()).toEqual([...node("apply-seams").output_format.required].sort());
    expect(node("slices").fan_out.items).toBe("$apply-seams.output.beads");
    expect(node("next").with).toEqual({ wave: "$apply-seams.output.beads", chain: "$apply-seams.output.tried" });
  });

  test.each([
    ["an empty wave", [] as string[]],
    ["a wave that dispatched", ["p.1"]],
  ])("next's output after %s is what next declares", (_name, wave) => {
    const r = run(["bun", NEXT], {
      INPUTS_PARENT: "p", INPUTS_BEADS_DIR: "/b", INPUTS_MAX_SLICES: "0",
      INPUTS_WAVE: JSON.stringify(wave), INPUTS_CHAIN: JSON.stringify(wave),
      WORKFLOW_ID: "w", ARCHON_CLI_COMMAND: '["archon"]',
      ARCHON_OUT: output("archon", '{"runId":"w2"}'),
    });
    expect(Object.keys(r.json()).sort()).toEqual([...node("next").output_format.required].sort());
  });
  test("close-parent's output is what close-parent declares, and it runs only when next ends the chain", () => {
    const r = run(["bun", CLOSE_PARENT], {
      INPUTS_PARENT: "p", INPUTS_BEADS_DIR: "/b",
      BD_OUT_list: output("bd-list", JSON.stringify([child("p.1")])),
    });
    expect(Object.keys(r.json()).sort()).toEqual([...node("close-parent").output_format.required].sort());
    expect(node("close-parent").when).toBe("$next.output.next_run == ''");
  });

  test("the end gate opens only when close-parent leaves the parent open, and only re-dispatch starts a wave", () => {
    const gate = node("end-gate");
    expect(gate.depends_on).toEqual(["close-parent"]);
    expect(gate.when).toBe("$close-parent.output.closed == false");
    expect(gate.wait.attention).toContain("$close-parent.output.reason");
    expect(gate.wait.options.map((o: any) => o.id)).toEqual(["redispatch", "stop"]);
    expect(node("redispatch").depends_on).toEqual(["end-gate"]);
    expect(node("redispatch").when).toBe("$end-gate.output.decision == 'redispatch'");
    expect(node("redispatch").with).toEqual({ chain: "$apply-seams.output.tried", text: "$end-gate.output.text" });

    const r = run(["bun", REDISPATCH], {
      INPUTS_PARENT: "p", INPUTS_BEADS_DIR: "/b", INPUTS_MAX_SLICES: "0", INPUTS_CHAIN: '["p.1"]', INPUTS_TEXT: "",
      WORKFLOW_ID: "w", ARCHON_CLI_COMMAND: '["archon"]',
      BD_OUT_list: output("bd-list", JSON.stringify([child("p.1")])),
      ARCHON_OUT: output("archon", '{"runId":"w2"}'),
    });
    expect(Object.keys(r.json()).sort()).toEqual([...node("redispatch").output_format.required].sort());
  });
});

describe("wave-status", () => {
  const WAVE_1 = "3fce6a9c3e8fffa03f9f278054f5e060";
  const WAVE_2 = "31ff052e5e4f68137f6a58d399333dbf";
  const WAVE_3 = "d92de4b0da5125ffc4d58dab4df9de60";

  type Run = Record<string, any>;
  // The listings were recorded before the seam gate existed. A wave now
  // records its settled wave as apply-seams' output, which for these waves,
  // with nothing dropped or moved out, is what ready picked.
  const recorded = (path: string): Run[] => {
    const runs: Run[] = JSON.parse(readFileSync(path, "utf8")).runs;
    for (const r of runs.filter((r) => r.workflow_name === "implement-in-waves")) {
      const ready = r.nodes.find((n: Run) => n.nodeId === "ready");
      r.nodes.push({ nodeId: "apply-seams", state: ready.state, output: ready.output });
    }
    return runs;
  };
  const listing = (runs: Run[]) => ({ ARCHON_OUT: output("archon", JSON.stringify({ runs })) });
  const status = (runs: Run[], id: string) => run([WAVE_STATUS, id, "--json"], listing(runs));
  const rows = (r: ReturnType<typeof run>): string[] =>
    r.json().rows.map((row: Run) => `${row.wave} ${row.bead} ${row.state}`);
  const slice = (runs: Run[], bead: string) => runs.find((r) => r.metadata.inputs.bead === bead)!;
  const node = (r: Run, id: string) => r.nodes.find((n: Run) => n.nodeId === id);

  test("reads Archon's whole run listing once, and nothing else", () => {
    status(recorded(FINAL), WAVE_1);
    expect(calls("archon").map((line) => line.split("\t")[1])).toEqual([
      "workflow runs --all --json --verbose --limit 1000",
    ]);
  });

  test("prints one row per bead across the chain, from any wave's id or a prefix of it", () => {
    for (const id of [WAVE_1, WAVE_3, "31ff052e"]) {
      const r = status(recorded(FINAL), id);
      expect(r.code).toBe(0);
      expect(r.json().waves.map((w: Run) => w.run)).toEqual([WAVE_1, WAVE_2, WAVE_3]);
      expect(rows(r)).toEqual(["1 wv-2nc.1 merged", "1 wv-2nc.2 released", "2 wv-2nc.3 merged"]);
      expect(r.json().chain).toBe("ended: wave 3 found no new ready child; the parent was not checked");
    }
  });

  test("names each slice's run and worktree", () => {
    const row = status(recorded(FINAL), WAVE_1).json().rows[0];
    expect(row.run).toBe("109417bb-839c-4538-8698-979806aca3bb");
    expect(row.worktree).toEndWith("/worktrees/archon/task-3fce6a9c-slices-ed08b2e0-child-0");
  });

  test("keeps another chain in the same records apart", () => {
    const r = status(recorded(FINAL), "6f74d027");
    expect(rows(r)).toEqual(["1 sm-cmj.1 failed, still claimed", "1 sm-cmj.2 released"]);
    expect(r.json().waves).toHaveLength(2);
  });

  test("a chain caught as its next wave starts shows that wave live and how to stop it", () => {
    const r = status(recorded(MIDRUN), WAVE_1);
    expect(r.json().waves.map((w: Run) => `${w.wave} ${w.status}`)).toEqual(["1 completed", "2 running"]);
    expect(rows(r)).toEqual(["1 wv-2nc.1 merged", "1 wv-2nc.2 released"]);
    expect(r.json().chain).toBe(`wave 2 is running; stop the chain with: archon workflow cancel ${WAVE_2}`);
  });

  test("the table form carries the same rows", () => {
    const r = run([WAVE_STATUS, WAVE_1], listing(recorded(FINAL)));
    expect(r.code).toBe(0);
    expect(r.stdout).toMatch(/^1 +wv-2nc\.2 +0a51a869-2804-491e-87d0-a3d9e6f3f595 +released +\/home\/user\//m);
    expect(r.stdout).toContain("chain: ended: wave 3 found no new ready child; the parent was not checked");
  });

  test.each([
    ["a running slice", (r: Run) => { r.status = "running"; }, "running"],
    ["a slice paused at its review gate", (r: Run) => { r.status = "paused"; }, "awaiting review"],
    ["a failed review", (r: Run) => {
      r.status = "failed";
      node(r, "close").state = "pending";
      r.nodes.push({ nodeId: "review", state: "failed" });
    }, "kept claimed"],
    ["a refused claim", (r: Run) => {
      node(r, "claim").state = "failed";
      node(r, "close").state = "skipped";
    }, "not claimed"],
    ["a slice cancelled after its claim", (r: Run) => {
      r.status = "cancelled";
      node(r, "close").state = "pending";
    }, "cancelled, still claimed"],
  ])("reports %s", (_name, mutate, state) => {
    const runs = recorded(FINAL);
    mutate(slice(runs, "wv-2nc.1"));
    expect(rows(status(runs, WAVE_1))[0]).toBe(`1 wv-2nc.1 ${state}`);
  });

  test("a bead the wave picked with no slice run is starting while the wave lives, not started after", () => {
    const runs = recorded(FINAL).filter((r) => r.parent_run_id !== WAVE_2);
    const wave2 = runs.find((r) => r.id === WAVE_2)!;
    wave2.status = "running";
    expect(rows(status(runs, WAVE_1))[2]).toBe("2 wv-2nc.3 starting");
    wave2.status = "completed";
    expect(rows(status(runs, WAVE_1))[2]).toBe("2 wv-2nc.3 not started");
  });

  test("lists the wave the seam gate settled, not every bead ready offered", () => {
    const runs = recorded(FINAL).filter((r) => r.parent_run_id !== WAVE_2);
    const wave2 = runs.find((r) => r.id === WAVE_2)!;
    node(wave2, "ready").output = JSON.stringify({ beads: ["wv-2nc.3", "wv-2nc.4"], count: 2 });
    node(wave2, "apply-seams").output = JSON.stringify({ beads: ["wv-2nc.3"], tried: [] });
    expect(rows(status(runs, WAVE_1)).filter((row) => row.startsWith("2 "))).toEqual(["2 wv-2nc.3 not started"]);
  });

  test("a wave paused at its seam gate lists none of ready's candidates", () => {
    const runs = recorded(FINAL).filter((r) => r.parent_run_id !== WAVE_2);
    const wave2 = runs.find((r) => r.id === WAVE_2)!;
    wave2.status = "paused";
    wave2.nodes = wave2.nodes.filter((n: Run) => n.nodeId !== "apply-seams");
    expect(rows(status(runs, WAVE_1)).filter((row) => row.startsWith("2 "))).toEqual([]);
  });

  test("says so when an earlier wave is outside the window", () => {
    const runs = recorded(FINAL).filter((r) => r.id !== WAVE_1 && r.parent_run_id !== WAVE_1);
    const r = status(runs, WAVE_3);
    expect(r.json().cut_off).toBe(true);
    expect(r.json().waves.map((w: Run) => w.run)).toEqual([WAVE_2, WAVE_3]);
  });

  test("a chain whose last wave failed before its next node reads as stopped", () => {
    const runs = recorded(FINAL);
    const wave3 = runs.find((r) => r.id === WAVE_3)!;
    wave3.status = "failed";
    wave3.nodes = [{ nodeId: "ready", state: "failed" }, { nodeId: "slices", state: "skipped" }, { nodeId: "next", state: "skipped" }];
    expect(status(runs, WAVE_1).json().chain).toBe("stopped: wave 3 failed");
  });

  test("a chain whose parent failed to close says so", () => {
    const runs = recorded(FINAL);
    const wave3 = runs.find((r) => r.id === WAVE_3)!;
    wave3.status = "failed";
    wave3.nodes.push({ nodeId: "close-parent", state: "failed" });
    expect(status(runs, WAVE_1).json().chain).toBe(
      `ended: wave 3 found no new ready child; closing the parent failed; see archon workflow get ${WAVE_3}`,
    );
  });

  test("a chain paused at its end gate says so, with the children still open", () => {
    const runs = recorded(FINAL);
    const wave3 = runs.find((r) => r.id === WAVE_3)!;
    wave3.status = "paused";
    wave3.nodes.push({ nodeId: "close-parent", state: "completed", output: JSON.stringify({
      closed: false, open: [{ id: "wv-2nc.2", status: "open", assignee: "" }], reason: "parent wv-2nc left open: wv-2nc.2 (open)",
    }) });
    expect(status(runs, WAVE_1).json().chain).toBe(
      `wave 3 found no new ready child and waits at its end gate in run ${WAVE_3}; parent wv-2nc left open: wv-2nc.2 (open)`,
    );
  });

  test("follows a chain into the wave its end gate re-dispatched", () => {
    const runs = recorded(FINAL);
    const wave4 = structuredClone(runs.find((r) => r.id === WAVE_2)!);
    wave4.id = "e4d0000000000000000000000000000a";
    wave4.started_at = "2099-01-01T00:00:00Z";
    wave4.metadata.inputs.previous = WAVE_3;
    const slice4 = structuredClone(slice(runs, "wv-2nc.3"));
    slice4.id = "slice-4";
    slice4.parent_run_id = wave4.id;
    slice4.metadata.inputs.bead = "wv-2nc.2";
    node(wave4, "apply-seams").output = JSON.stringify({ beads: ["wv-2nc.2"], tried: [] });
    runs.push(wave4, slice4);
    const r = status(runs, WAVE_1);
    expect(r.json().waves.map((w: Run) => w.run)).toEqual([WAVE_1, WAVE_2, WAVE_3, wave4.id]);
    expect(rows(r)).toContain("4 wv-2nc.2 merged");
  });

  test.each([
    ["an unknown run", ["nope"], "no implement-in-waves run nope"],
    ["no run id", [], "usage"],
    ["two run ids", [WAVE_1, WAVE_3], "usage"],
  ])("refuses %s", (_name, args, message) => {
    const r = run([WAVE_STATUS, ...args], listing(recorded(FINAL)));
    expect(r.code).toBe(2);
    expect(r.stderr).toContain(message);
  });

  test("refuses a prefix that names several waves", () => {
    const runs = recorded(FINAL);
    runs.find((r) => r.id === WAVE_3)!.id = "3fce6a9cffff";
    const r = status(runs, "3fce6a9c");
    expect(r.code).toBe(2);
    expect(r.stderr).toContain("names 2 implement-in-waves runs");
  });

  test("fails when Archon cannot list runs", () => {
    const r = run([WAVE_STATUS, WAVE_1], { ARCHON_EXIT: "1" });
    expect(r.code).toBe(2);
    expect(r.stderr).toContain("archon workflow runs exited 1");
  });
});

// Drives dispatch-wave's two scripts and wave-status as the engine and a
// person run them, with `bd` and `archon` replaced by stubs on PATH. Each stub
// appends its argv to a log and prints what the test told it to.

import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ROOT = resolve(import.meta.dir, "..");
const READY = join(ROOT, "workflows/dispatch-wave/scripts/ready.ts");
const NEXT = join(ROOT, "workflows/dispatch-wave/scripts/next.ts");
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
// <NAME>_OUT, exiting with <NAME>_EXIT.
function stub(name: string) {
  const path = join(bin, name);
  const upper = name.toUpperCase();
  writeFileSync(
    path,
    `#!/bin/bash
printf '%s\\t%s\\n' "\${BEADS_DIR:-}" "$*" >> "${bin}/${name}.log"
[ -n "\${${upper}_OUT:-}" ] && cat "\${${upper}_OUT}"
exit "\${${upper}_EXIT:-0}"
`,
  );
  chmodSync(path, 0o755);
}

function output(name: string, text: string): string {
  const path = join(bin, `${name}.out`);
  writeFileSync(path, text);
  return path;
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
  bin = realpathSync(mkdtempSync(join(tmpdir(), "dispatch-wave-test.")));
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
    const r = run(["bun", READY], { ...inputs(), BD_OUT: output("bd", JSON.stringify(rows)) });
    expect(r.json()).toEqual({ beads: ["p.1", "p.2"], tried: ["p.1", "p.2"] });
  });

  test("skips a bead an earlier wave of the chain tried, and carries the chain's list on", () => {
    const rows = [child("p.1"), child("p.2"), child("p.3")];
    const r = run(["bun", READY], {
      ...inputs({ INPUTS_TRIED: '["p.1"]' }),
      BD_OUT: output("bd", JSON.stringify(rows)),
    });
    expect(r.json()).toEqual({ beads: ["p.2", "p.3"], tried: ["p.1", "p.2", "p.3"] });
  });

  test("max_slices caps the wave and leaves the rest for later waves", () => {
    const rows = [child("p.1"), child("p.2"), child("p.3")];
    const r = run(["bun", READY], {
      ...inputs({ INPUTS_MAX_SLICES: "2" }),
      BD_OUT: output("bd", JSON.stringify(rows)),
    });
    expect(r.json()).toEqual({ beads: ["p.1", "p.2"], tried: ["p.1", "p.2"] });
  });

  test("an empty frontier is an empty wave, not a failure", () => {
    const r = run(["bun", READY], { ...inputs(), BD_OUT: output("bd", "[]") });
    expect(r.code).toBe(0);
    expect(r.json()).toEqual({ beads: [], tried: [] });
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
    expect(argv).toContain("workflow run dispatch-wave --detach --json --cwd ");
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

// The fixtures stub both scripts away and the tests above hand-set their
// inputs, so both stay green if the workflow and a script drift apart. This
// reads what dispatch-wave.yaml declares about each script node and holds the
// real script to it: every INPUTS_* name the script reads is a workflow input
// or one of the node's `with:` names, and its real output carries exactly the
// declared required fields.
describe("dispatch-wave.yaml wiring", () => {
  const workflow = Bun.YAML.parse(readFileSync(join(ROOT, "workflows/dispatch-wave/dispatch-wave.yaml"), "utf8")) as any;
  const node = (id: string) => workflow.nodes.find((n: any) => n.id === id);
  const envName = (name: string) => `INPUTS_${name.toUpperCase()}`;

  test.each([["ready", READY], ["next", NEXT]])("every input %s reads is bound", (id, path) => {
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
    expect(node("slices").fan_out.items).toBe("$ready.output.beads");
    expect(node("next").with).toEqual({ wave: "$ready.output.beads", chain: "$ready.output.tried" });
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
});

describe("wave-status", () => {
  const WAVE_1 = "3fce6a9c3e8fffa03f9f278054f5e060";
  const WAVE_2 = "31ff052e5e4f68137f6a58d399333dbf";
  const WAVE_3 = "d92de4b0da5125ffc4d58dab4df9de60";

  type Run = Record<string, any>;
  const recorded = (path: string): Run[] => JSON.parse(readFileSync(path, "utf8")).runs;
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
      expect(r.json().chain).toBe("ended: wave 3 found no new ready child");
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
    expect(r.stdout).toContain("chain: ended: wave 3 found no new ready child");
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

  test("says so when an earlier wave is outside the window", () => {
    const runs = recorded(FINAL).filter((r) => r.id !== WAVE_1 && r.parent_run_id !== WAVE_1);
    const r = status(runs, WAVE_3);
    expect(r.json().cut_off).toBe(true);
    expect(r.json().waves.map((w: Run) => w.run)).toEqual([WAVE_2, WAVE_3]);
  });

  test("a chain whose last wave failed reads as stopped", () => {
    const runs = recorded(FINAL);
    runs.find((r) => r.id === WAVE_3)!.status = "failed";
    expect(status(runs, WAVE_1).json().chain).toBe("stopped: wave 3 failed");
  });

  test.each([
    ["an unknown run", ["nope"], "no dispatch-wave run nope"],
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
    expect(r.stderr).toContain("names 2 dispatch-wave runs");
  });

  test("fails when Archon cannot list runs", () => {
    const r = run([WAVE_STATUS, WAVE_1], { ARCHON_EXIT: "1" });
    expect(r.code).toBe(2);
    expect(r.stderr).toContain("archon workflow runs exited 1");
  });
});

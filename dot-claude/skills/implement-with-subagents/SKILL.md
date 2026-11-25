---
name: implement-with-subagents
description: Orchestrate one vertical slice across subagents, attended or `--unattended`. Parent plans, delegates and injects expected values; workers do TDD on a controllable model, then hand off to the repo's ship flow.
disable-model-invocation: true
---
# Implement With Subagents

Runs Matt Pocock's `implement` recipe with the actual work in **subagents**, because the parent can't downgrade its own model mid-task. The **parent is an orchestrator only**: it plans, agrees the design, picks models, injects expected values, and decides. **Workers** run the code via TDD on a model you control. §8 states how the run ends.

## Input

One **slice**, given as a bead id, a path, or a description. Flags: `--unattended`, and unattended-only `--model=<id>` and `--parallel-safe`. §3 owns model choice.

## Vocabulary

Each word sits at one level. Keep it there.

- **slice**. One vertical slice, arriving already sliced from planning. The skill's input, never something this skill produces.
- **seam**. A public boundary inside the slice: the *location* where an interface lives. §1 finds them, §2 agrees them. A seam is placed, never built, owned or run green.
- **assignment**. A body of code that meets a seam's interface, and the unit that gets its own contract, expected values and tests. Under **split** it is also the unit one worker owns. A seam yields **one assignment per participant**, however many that is; several participants at one seam is the parallel case (§1).
- **scenario**. One behaviour of one assignment, as Gherkin at that assignment's seam: the slice's spec. `DESIGN.md` *Scenarios* says where they come from, where they live, and which need the engineer's approval. Many scenarios per assignment.
- **cycle**. One failing test plus the minimum code to green it. One scenario is one cycle's red test. Many cycles per assignment: the first trivially small, each one after building on what the last taught.

## Arms

Every run is one sample in an A/B experiment on how many implementers a slice gets. Both arms share everything else, the parent-written expected values above all. They differ only in §1's parallel tags, §3's model pick, and §4's dispatch and fit-overflow handling.

- **split**. One implementer per assignment.
- **single**. One implementer for the whole slice, working every assignment in §1's order.

**Assign the arm first, before §1.** Run `~/.claude/skills/implement-with-subagents/ab.sh assign <slice-id>`, adding `--unattended` when unattended. The slice id is the bead id, or the spec's path relative to the repo root; pass `""` for a free-text slice. It prints `run` and `arm`: keep `run` for §7, and run the printed arm for the whole slice, however the slice looks. The hash is the randomisation, so a hunch about which arm suits the slice is exactly the selection bias it exists to remove. Where the user explicitly directs the other arm, follow them and pass `--forced` at §7.

## Unattended mode

`--unattended` runs the whole skill with nobody in the room, so a workflow node can drive it. One rule governs it: **never call `AskUserQuestion` and never wait for a reply**. Every gate has a stated default here; take it, and name the ones you took in the §8 report. Orthogonal to the arm. Without the flag, every gate behaves exactly as its section says.

| Gate | Unattended default |
| --- | --- |
| §1, adopting scenarios in a suite that has none | Skip the recommendation, take §1's no-scenario path. File a bead recommending adoption. |
| §1 or §4, a new scenario, or a change of meaning to an approved one | Proceed. Record it as `DESIGN.md` *Scenarios* *In the build* says. |
| §1, composition left unobserved by the union of scenarios | Write no cross-service test. File a bead naming the gap. |
| §1 or §4, the slice itself doesn't fit | File a bead recording the overflow and the suggested split, leave the tree uncommitted, and end the run by emitting the §8 report with `status: aborted` and `reason` naming the overflow. Covers both §1's slice-level fit check and a §4 re-split that still overflows. |
| §2 default, seam list | Proceed on the §1 seam list unchanged. |
| §2 gate fired | Run the red-team reviewer (step 2) and revise, then proceed on the revised design. Record every assumption in the §8 report rather than presenting it. |
| §2, a cycle shows a seam is in the wrong place | Move it, whatever its source. Where the gate fired, red-team the new placement. Record the move and its reason for §8's `seams`. |
| §3, model selection | One flat default, `sonnet`, for every implementer in either arm. `--model=<id>` replaces that default for the whole run. |
| §4, a worker escalates that the contract is wrong | Re-derive the expected values from the spec, revise the contract, redispatch once. On a second escalation for the same assignment, file a bead recording the disagreement, leave the tree uncommitted, and end the run by emitting the §8 report with `status: aborted` and `reason` naming the disagreement. |
| §5, a fan-in check the parent cannot get green | Triage and dispatch as §5 says. Where triage runs out, file a bead naming the failing check, leave the tree uncommitted, and end the run by emitting the §8 report with `status: aborted` and `reason` naming the check. |
| §7, a survivor-closing test fails on the unchanged commit | Take the parent's call as METRICS.md step 2 says. A survivor still open after one redispatch stays open, named in `--note`. |
| §8, hand off | The workflow node drives `no-mistakes`. The parent never invokes it. |

**Parallel tags** (split only). Unattended, every assignment is **sequential** unless the caller passes `--parallel-safe`, a run-level boolean asserting one thing only: every assignment in the slice has an import graph disjoint from its siblings (§1 gives why the import graph is the test). The parent cannot establish disjointness from a ticket alone. With the flag set, the parent still applies §1's truth-independence test per assignment and tags **sequential** any assignment whose expected values come from a sibling's work. Sequential costs wall-clock and nothing else.

## 1. Seams and assignments

**Read `DESIGN.md` before anything else.** Its *Seams* and *Scenarios* rules govern this section, and its *Design gate* governs §2.

Parent reads the slice and the relevant code, then produces:

- The **seams** to test at, placed and sourced per `DESIGN.md` *Seams*.
- The **assignments** each seam yields.
- An **order**, so each assignment's cycles teach the next.
- A **parallel tag** per assignment, under split only; single's one worker runs them in order. **Parallel when truth is independent:** one assignment can proceed beside another exactly when its expected values come from outside the sibling work, the spec, an agreed contract, a worked example. An assignment whose correctness can only be judged against what another worker is producing is sequential. Disjoint files is not the test; parallel workers need disjoint **import graphs**, or a sibling's half-written code reds their run. A suite's shared step-definition file is one such graph: assignments landing in the same suite either run sequentially or each take their own step file.
- A **fit check** per assignment: it must comfortably fit one worker context window. An assignment that doesn't fit splits, adding a seam if the split needs one. A *slice* that doesn't fit goes back to planning to be split there (unattended: *Unattended mode*). Under single, the one worker carrying a slice whose assignments each fit is §4's *Fit overflow* to handle at run time, so it is no reason to send the slice back.
- The **scenarios** per assignment, per `DESIGN.md` *Scenarios*: the approved set first, each one realised at an assignment's seam, then any the slice still needs. Each hands §4 the feature file it matches against, or is marked not persisted. A composition gap is the parent's to raise (unattended: *Unattended mode*).

**A suite carrying no `.feature` files yet** keeps the repo's existing test idiom: its scenarios stay unpersisted Gherkin, each one cycle's spec. Where the slice looks like a good place to adopt them, recommend it via `AskUserQuestion` and wait (unattended: *Unattended mode*): on yes, the layout, runner wiring and shared step file become their own assignment, ordered first and sequential, since every later assignment reads the conventions it establishes. Once that lands the suite carries its own signal and later slices detect it.

Done when every seam has its source and its assignments, and every assignment an order position, under split a parallel/sequential tag, a fit check, and its scenarios, with every one beyond the approved set marked unapproved.

## 2. Agree the design

Per `tdd`: a seam is confirmed before its first test. Parent's job, before any model pick or cycle. How much gets confirmed depends on how much design the slice carries.

**Default**. Present the §1 seam list, confirm (unattended: *Unattended mode*).

**Design gate**. Fires on any trigger `DESIGN.md` *Design gate* lists.

1. Parent drafts the design `DESIGN.md` *What the design carries* spells out, at its resolution gradient.
2. **Red-team**: dispatch one reviewer worker (Agent, `general-purpose`), instructed to **load `codebase-design` itself** (subagents don't inherit the parent's loaded skills): flag every hop that only forwards arguments, every seam nothing actually varies across ("one adapter means a hypothetical seam"), and every cited existing symbol it can't find in the repo. Parent revises.
3. Present, and wait for the answer (unattended: *Unattended mode*).

A seam a later cycle teaches you is in the wrong place re-enters this gate (unattended: *Unattended mode*); a seam never moves silently.

Done, on the **Default** path, when the seam list is confirmed, or, unattended, when the parent proceeds on the §1 seam list unchanged. Done, when the gate fired, when the first seam has a confirmed signature, owning module, failure semantics and one-way/reversible tag, and every later seam has at least the coarse version of those. Unattended, the step 2 red-team stands in for the confirmation, and every assumption goes into the §8 report; attended, every assumption is either approved or replaced.

## 3. Model selection

Starts only once §2 is done. The approved design is what you judge difficulty against, and a pick made before it is a guess.

Judge the difficulty of the work and **recommend** an implementer model via `AskUserQuestion`, offering alternatives + Other, with your reasoning. Wait for the pick (unattended: *Unattended mode*).

Implementers lean cheaper, since they only make an existing expectation green. Under **split**, recommend per assignment; assignments may run on different models, and attended, re-recommend for one that turns out far harder or easier. Under **single**, recommend one model for the slice, judged by its hardest assignment. Unattended, the flat default holds for every implementer.

## 4. TDD loop, per assignment

The parent is the **loop driver**: it invokes the `tdd` skill itself to carry the red-green rules and anti-patterns, and carries adaptive state between assignments. Testing bias is handled by the **Bias guard** layers below.

**Both arms.** Per assignment, the parent writes the contract and expected values, the assignment's **scenario text** among them: it *is* an expected value, so a worker authoring its own would spend the bias guard. Every implementer is an Agent (`general-purpose`, chosen model), told to **load `tdd` itself** (same reason as §2 step 2). It works in **cycles**, preserving every assertion and injected expected value as given. If it judges a contract wrong, it stops and escalates to the parent (unattended: *Unattended mode*).

- **split**. One implementer per assignment, given only that assignment and its contract + expected values.
- **single**. One implementer, dispatched once with every assignment and its contract + expected values, in §1's order. It finishes one assignment green before starting the next. When a contract escalation interrupts it, the redispatch hands one fresh implementer the green work, the escalated assignment and every assignment after it, in §1's order. This keeps the run single-implementer, distinct from the fit fallback. A §5 triage dispatch works as under split: one implementer gets the failing check and the green tree.

**When the §2 gate fired:** the signature and failure semantics of the assignment's seam are part of the contract the worker must hold. The flow diagram is not.

**Scenarios in the loop:** one scenario per cycle. In a suite with `.feature` files, a worker matches the suite's conventions against the feature file §1 hands it, reuses an existing step definition wherever one fits, and adds genuinely new steps to the suite's shared file. In a suite without, the worker implements the scenario's Gherkin as a test in the suite's idiom. A worker that needs a scenario changed in meaning escalates it like a wrong contract.

**In-loop verification:** each cycle runs the worker's own test file, nothing wider. Project-wide typecheck and the full suite wait for §5. A wide check run under parallel workers reports a sibling's unfinished code as your own failure.

**Fit overflow:** a worker whose work turns out not to fit returns "doesn't fit" with a split suggestion instead of pushing through. Under split, the parent splits the assignment per §1. Under single, the parent keeps what is green and dispatches one implementer per remaining assignment, sequentially in §1's order, on the slice's model, then passes `--fit-fallback` at §7; the run still counts as single. On a `--forced` run, leave out `--fit-fallback` and record the fallback in `--note` (`ab.sh` checks the start row's hashed arm). A re-split that still overflows goes back to planning (unattended: *Unattended mode*).

An assignment is done when its tests are green; the loop is done when every assignment is done.

## 5. Fan-in check

Every assignment green, parent runs the project-wide checks the workers deferred: full typecheck, full test suite, and contract conformance where the repo can bring a provider up locally. Failures here are integration failures between assignments, the parent's to triage and dispatch, since no single worker can see them. Count each check that fails on its first run, for §7's `--fanin-failures`. Done when the tree is green.

## 6. Commit

Commit on a **feature branch** (create one if on the default branch, since the ship flow validates committed history on a non-default branch).

Unattended, the commit message ends in git trailers: one `Seam:` per §8 `seams` line, one `Assumption:` per §8 `assumptions` entry and one `Unapproved-Scenario:` per §8 `unapproved scenarios` entry, each on a single line. The report itself reaches no reviewer; slice-pipeline copies these trailers into the findings record on the pull request.

Done when the whole slice is one commit on a feature branch, its message ending in the `Seam:`, `Assumption:` and `Unapproved-Scenario:` trailers when unattended.

## 7. Metrics

Every run ends with one `ab.sh finish` call, aborted runs included, before the §8 report. `METRICS.md` gives the call, and the mutation-proxy procedure that comes before it.

## 8. Stop and hand off

Stop at the commit. Review, lint, push, PR and CI belong to the repo's **ship flow**: the PR pipeline its `CLAUDE.md` or `CLAUDE.local.md` names, or `no-mistakes` where it names none.

**Attended.** Report in one line that the work is ready, naming the branch and appending the `notices` field defined below, and stop there. The user drives the ship flow themselves; it has gates only they should answer.

**Unattended.** Report one field per line, so the workflow node can parse what it needs to drive `no-mistakes` next:

- `status`, one of `ready` or `aborted`. `aborted` on any run a table row ends uncommitted; `branch` and `sha` are absent then.
- `reason`, present only when `status` is `aborted`, one line saying what the parent could not resolve. Every abort row writes it.
- `branch`, the feature branch name.
- `sha`, the slice's final commit: the §6 commit as amended in §7.
- `gate defaults taken`, one line each, naming the gate and the default.
- `seams`, one line each: the seam, its §1 source, and for a moved seam the reason.
- `assumptions`, every §2 assumption the parent recorded rather than presented.
- `unapproved scenarios`, one line each: the feature file or suite, the scenario's name, and `new` or `changed:` with what its meaning gained or lost.
- `scenario map`, for each suite without `.feature` files, one line per test: the test, then the scenario it implements.
- `beads filed`, one id and title each.
- `notices`, every `ab.sh` warning (stderr) and `finish`'s stopping-point line.

## Bias guard, three layers

Testing bias is caught in three places, so per-assignment test auditing is redundant:

1. **parent expected-value injection**, §4, in both arms.
2. **comprehensive-code-review Tests aspect**, downstream in the ship flow's review (catches tautological / impl-coupled / weak-assertion tests).
3. **mutation proxy**, §7: measures the kill rate, then closes each survivor with a test.

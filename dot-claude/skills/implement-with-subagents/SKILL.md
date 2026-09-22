---
name: implement-with-subagents
description: Orchestrate one vertical slice across subagents, attended or `--unattended`. Parent plans and delegates, workers do TDD on a controllable model, then hand off to no-mistakes.
disable-model-invocation: true
---
# Implement With Subagents

Runs Matt Pocock's `implement` recipe with the actual work in **subagents**, because the parent can't downgrade its own model mid-task. The **parent is an orchestrator only**: it plans, agrees the design, picks models, injects expected values, and decides. **Workers** run the code via TDD on a model you control. §8 states how the run ends.

## Input

One **slice**, given as a bead id, a path, or a description. Flags: `--solo`, `--unattended`, and unattended-only `--model=<id>` and `--parallel-safe`. §2 owns model choice.

## Vocabulary

Each word sits at one level. Keep it there.

- **slice**. One vertical slice, arriving already sliced from planning. The skill's input, never something this skill produces.
- **seam**. A public boundary inside the slice: the *location* where an interface lives. §1 finds them, §3 agrees them. A seam is placed, never built, owned or run green.
- **assignment**. A body of code that meets a seam's interface, and the unit one worker owns. A seam yields **one assignment per participant**, however many that is; several participants at one seam is the parallel case (§1).
- **scenario**. One behaviour of one assignment, as Gherkin at that assignment's seam and in that suite's language, where the suite expresses its tests that way. §1 derives them from the ticket's slice-wide acceptance criteria. Many scenarios per assignment.
- **cycle**. One failing test plus the minimum code to green it. One scenario is one cycle's red test. Many cycles per assignment: the first trivially small, each one after building on what the last taught.

## Modes

- **guarded** (default). Anti-bias arm: the parent injects the expected values (mechanism in §4).
- `--solo`. One worker takes the whole slice, every assignment, and derives its own expected values. §1's parallel tags don't apply and §2 picks one model for the slice. Cheaper/faster when bias isn't a concern, and doubles as the **metrics baseline** for comparing against guarded.

## Unattended mode

`--unattended` runs the whole skill with nobody in the room, so a workflow node can drive it. One rule governs it: **never call `AskUserQuestion` and never wait for a reply**. Every gate has a stated default here; take it, and name the ones you took in the §8 report. Orthogonal to guarded/`--solo`, which still picks the bias arm. Without the flag, every gate behaves exactly as its section says.

| Gate | Unattended default |
| --- | --- |
| §1, adopting scenarios in a suite that has none | Skip the recommendation, take §1's no-scenario path. File a bead recommending adoption. |
| §1, composition left unobserved by the union of scenarios | Write no cross-service test. File a bead naming the gap. |
| §1 or §4, the slice itself doesn't fit | File a bead recording the overflow and the suggested split, leave the tree uncommitted, and end the run by emitting the §8 report with `status: aborted` and `reason` naming the overflow. Covers both §1's slice-level fit check and a §4 re-split that still overflows. |
| §2, model selection | One flat default across every assignment: `sonnet` under guarded, `opus` for the one worker under `--solo`. `--model=<id>` replaces that default for the whole run. |
| §3 default, seam list | Proceed on the §1 seam list unchanged. |
| §3 gate fired | Run the red-team reviewer (step 2) and revise, then proceed on the revised design. Record every assumption in the §8 report rather than presenting it. |
| §4, a worker escalates that the contract is wrong | Re-derive the expected values from the spec, revise the contract, redispatch once. On a second escalation for the same assignment, file a bead recording the disagreement, leave the tree uncommitted, and end the run by emitting the §8 report with `status: aborted` and `reason` naming the disagreement. |
| §5, a fan-in check the parent cannot get green | Triage and dispatch as §5 says. Where triage runs out, file a bead naming the failing check, leave the tree uncommitted, and end the run by emitting the §8 report with `status: aborted` and `reason` naming the check. |
| §8, hand off | The workflow node drives `no-mistakes`. The parent never invokes it. |

**Parallel tags.** Unattended, every assignment is **sequential** unless the caller passes `--parallel-safe`, a run-level boolean asserting one thing only: every assignment in the slice has an import graph disjoint from its siblings (§1 gives why the import graph is the test). The parent cannot establish disjointness from a ticket alone. With the flag set, the parent still applies §1's truth-independence test per assignment and tags **sequential** any assignment whose expected values come from a sibling's work. Sequential costs wall-clock and nothing else.

## 1. Seams and assignments

**Load `codebase-design` before anything else.** Its vocabulary and seam rules govern this section and §3: the interface is the test surface, and one adapter means a hypothetical seam. Placing a seam where no test can live is the failure this catches.

Parent reads the slice and the relevant code, then produces:

- The **seams** to test at, public boundaries only.
- The **assignments** each seam yields.
- An **order**, so each assignment's cycles teach the next.
- A **parallel tag** per assignment. **Parallel when truth is independent:** one assignment can proceed beside another exactly when its expected values come from outside the sibling work, the spec, an agreed contract, a worked example. An assignment whose correctness can only be judged against what another worker is producing is sequential. Disjoint files is not the test; parallel workers need disjoint **import graphs**, or a sibling's half-written code reds their run. A suite's shared step-definition file is one such graph: assignments landing in the same suite either run sequentially or each take their own step file.
- A **fit check** per assignment: it must comfortably fit one worker context window. An assignment that doesn't fit splits, adding a seam if the split needs one. A *slice* that doesn't fit goes back to planning to be split there (unattended: *Unattended mode*).
- The **scenarios** per assignment, where the suite expresses its tests as scenarios. One glob for `**/*.feature` settles it, per suite, and hands §4 the file it matches against. Derived from the ticket's behavioural acceptance criteria, which are slice-wide and mechanism-free by construction: here each is realised at the seam that can observe it. A criterion spanning several assignments splits across the ones that can, plus a `@contract` scenario at each boundary it crosses, cited against the `contract-approval` record. A `@contract` scenario pins semantics the contract artifact cannot express: idempotent replay, retry thresholds, state transitions, ordering, emission obligations. One needing a mock response the artifact does not yet describe extends the artifact in the same slice. Where the union still leaves the composition itself unobserved, say so and raise it: that gap is the one thing earning a cross-service test, and it is the parent's call, not a worker's (unattended: *Unattended mode*).

**A suite carrying no scenarios yet** keeps the repo's existing test idiom, and §4 runs plain cycles. Where the slice looks like a good place to adopt them, recommend it via `AskUserQuestion` and wait (unattended: *Unattended mode*): on yes, the layout, runner wiring and shared step file become their own assignment, ordered first and sequential, since every later assignment reads the conventions it establishes. Once that lands the suite carries its own signal and later slices detect it.

Done when every seam has its assignments, and every assignment an order position, a parallel/sequential tag, a fit check, and, where the suite carries scenarios, its scenarios.

## 2. Model selection

Judge the difficulty of the work and **recommend** an implementer model via `AskUserQuestion`, offering alternatives + Other, with your reasoning. Wait for the pick (unattended: *Unattended mode*).

Under **guarded**, recommend per assignment. Implementers lean cheaper, since they only make an existing expectation green, and assignments may run on different models. Attended, re-recommend for one that turns out far harder or easier; unattended, the flat default holds for every assignment.

Under `--solo`, recommend once for the slice, a tier up: that worker designs the contract and derives its own expected values.

## 3. Agree the design

Per `tdd`: a seam is confirmed before its first test. Parent's job, before any cycle. How much gets confirmed depends on how much design the slice carries.

**Default**. Present the §1 seam list, confirm (unattended: *Unattended mode*).

**Design gate**. Fires when the slice does any of: introduces a **new module**; adds an **internal seam** (one `contract-approval` doesn't already gate); or spans **≥4 hops across ≥2 existing modules**. These are the decompositions TDD can't reach. It drives what an assignment contains, never where the seam goes.

1. Parent drafts the design below.
2. **Red-team**: dispatch one reviewer worker (Agent, `general-purpose`), instructed to **load `codebase-design` itself** (subagents don't inherit the parent's loaded skills): flag every hop that only forwards arguments, every seam nothing actually varies across ("one adapter means a hypothetical seam"), and every cited existing symbol it can't find in the repo. Parent revises.
3. Present, and wait for the answer (unattended: *Unattended mode*).

The design carries:

- **Seam signatures**. Real typed signatures, living as text in the review artifact; the repo stays untouched until §4. Seams only, never every hop. A cross-boundary seam cites its `contract-approval` record instead of re-litigating shape.
- **Module ownership**. Which module owns each new piece of behaviour.
- **Failure semantics**. Per seam: what throws, what catches it, what partial state survives.
- **One-way doors**. Each seam tagged reversible or expensive-to-change, so review attention lands on the ones that matter.
- **Flow**. Entry point through the hops, as a diagram, marked **illustrative and non-binding**: interior structure belongs to the refactor step, and a worker stays free to deviate from it.
- **Assumptions**. Every place the spec was silent and the parent chose.

**Resolution gradient:** the first seam in full detail, later seams coarse. A seam a later cycle teaches you is in the wrong place re-enters this gate; a seam never moves silently.

Done, on the **Default** path, when the seam list is confirmed, or, unattended, when the parent proceeds on the §1 seam list unchanged. Done, when the gate fired, when the first seam has a confirmed signature, owning module, failure semantics and one-way/reversible tag, and every later seam has at least the coarse version of those. Unattended, the step 2 red-team stands in for the confirmation, and every assumption goes into the §8 report; attended, every assumption is either approved or replaced.

## 4. TDD loop, per assignment

The parent is the **loop driver**: it invokes the `tdd` skill itself to carry the red-green rules and anti-patterns, and carries adaptive state between assignments. Testing bias is handled by the **Bias guard** layers below.

**guarded**, per assignment:

- Parent writes the contract and expected values (sourced from spec / worked example / known-good literal), the assignment's **scenario text** among them: it *is* an expected value, so a worker authoring its own would spend the anti-bias arm.
- Dispatch one implementer worker (Agent, `general-purpose`, chosen model) given only: the assignment, the contract + expected values, and an instruction to **load `tdd` and `coding-standards` itself** (same reason as §3 step 2). It works in **cycles**, preserving every assertion and injected expected value as given. If it judges the contract wrong, it stops and escalates to the parent (unattended: *Unattended mode*).

`--solo`. One worker, dispatched once with the whole slice and its confirmed seams, writing every contract, test and implementation itself; no parent expected-value injection.

**When the §3 gate fired:** the signature and failure semantics of the assignment's seam are part of the contract the worker must hold. The flow diagram is not.

**Scenarios in the loop:** one scenario per cycle, red before green. A worker matches the suite's conventions against the feature file §1 hands it, reuses an existing step definition wherever one fits, and adds genuinely new steps to the suite's shared file.

**In-loop verification:** each cycle runs the worker's own test file, nothing wider. Project-wide typecheck and the full suite wait for §5. A wide check run under parallel workers reports a sibling's unfinished code as your own failure. An assignment that changes a contract artifact is the exception: it runs conformance for that artifact in-loop, since its truth is self-contained and no sibling can red it.

**Fit overflow:** a worker whose assignment turns out not to fit returns "doesn't fit" with a split suggestion instead of pushing through; parent splits it per §1. A re-split that still overflows goes back to planning (unattended: *Unattended mode*).

An assignment is done when its tests are green; the loop is done when every assignment is done.

## 5. Fan-in check

Every assignment green, parent runs the project-wide checks the workers deferred: full typecheck, full test suite, and contract conformance where the repo can bring a provider up locally. Failures here are integration failures between assignments, the parent's to triage and dispatch, since no single worker can see them. Done when the tree is green.

## 6. Commit

Commit on a **feature branch** (create one if on the default branch, since no-mistakes validates committed history on a non-default branch).

Done when the whole slice is one commit on a feature branch.

## 7. Metrics

Record one metrics line per run, including a run an abort row ended, and record it before the §8 report. See `METRICS.md` for the schema and the mutation-proxy procedure.

## 8. Stop and hand off

Stop at the commit. Review, lint, push, PR and CI belong to `no-mistakes`.

**Attended.** Report in one line that the work is ready, naming the branch, and stop there. The user drives `no-mistakes` themselves; it has gates only they should answer.

**Unattended.** Report one field per line, so the workflow node can parse what it needs to drive `no-mistakes` next:

- `status`, one of `ready` or `aborted`. `aborted` on any run a table row ends uncommitted; `branch` and `sha` are absent then.
- `reason`, present only when `status` is `aborted`, one line saying what the parent could not resolve. Every abort row writes it.
- `branch`, the feature branch name.
- `sha`, the §6 commit.
- `gate defaults taken`, one line each, naming the gate and the default.
- `assumptions`, every §3 assumption the parent recorded rather than presented.
- `beads filed`, one id and title each.

## Bias guard, three layers

Testing bias is caught in three places, so per-assignment test auditing is redundant:

1. **guarded expected-value injection**, §4.
2. **comprehensive-code-review Tests aspect**, downstream via no-mistakes (catches tautological / impl-coupled / weak-assertion tests).
3. **mutation-proxy metric**, §7.

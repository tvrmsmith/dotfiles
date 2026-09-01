---
name: implement-with-subagents
description: Orchestrate a spec/tickets implementation across subagents. Parent plans and delegates, workers do TDD on a controllable model, then hand off to no-mistakes.
disable-model-invocation: true
---
# Implement With Subagents

Runs Matt Pocock's `implement` recipe with the actual work in **subagents**, because the parent can't downgrade its own model mid-task. That's why subagents exist at all here. The **parent is an orchestrator only**: it plans, agrees the design, picks models, injects expected values, and decides. **Workers** run the code via TDD on a model you control. The skill ends when the work is TDD-implemented and committed on a feature branch, then stops and hands off to `no-mistakes` (see §8).

## Input

One **slice**, given as a bead id, a path, or a description. Flag: `--solo`. §2 owns model choice.

## Vocabulary

Each word sits at one level. Keep it there.

- **slice**. One vertical slice, arriving already sliced from planning. The skill's input, never something this skill produces.
- **seam**. A public boundary inside the slice: the *location* where an interface lives. §1 finds them, §3 agrees them. A seam is placed, never built, owned or run green.
- **assignment**. A body of code that meets a seam's interface, and the unit one worker owns. A seam yields **one assignment per participant**, however many that is; several participants at one seam is the parallel case (§1).
- **scenario**. One behaviour of one assignment, as Gherkin at that assignment's seam and in that suite's language, where the suite expresses its tests that way. §1 derives them from the ticket's slice-wide acceptance criteria. Many scenarios per assignment.
- **cycle**. One failing test plus the minimum code to green it. One scenario is one cycle's red test. Many cycles per assignment: the first trivially small, each one after building on what the last taught.

## Modes

- **guarded** (default). Anti-bias arm: the parent injects the expected values (mechanism in §4).
- `**--solo**`. One worker takes the whole slice, every assignment, and derives its own expected values. §1's parallel tags don't apply and §2 picks one model for the slice. Cheaper/faster when bias isn't a concern, and doubles as the **metrics baseline** for comparing against guarded.

## 1. Seams and assignments

**Load `codebase-design` before anything else.** Its vocabulary and seam rules govern this section and §3: the interface is the test surface, and one adapter means a hypothetical seam. Placing a seam where no test can live is the failure this catches.

Parent reads the slice and the relevant code, then produces:

- The **seams** to test at, public boundaries only.
- The **assignments** each seam yields.
- An **order**, so each assignment's cycles teach the next.
- A **parallel tag** per assignment. **Parallel when truth is independent:** one assignment can proceed beside another exactly when its expected values come from outside the sibling work, the spec, an agreed contract, a worked example. An assignment whose correctness can only be judged against what another worker is producing is sequential. Disjoint files is not the test; parallel workers need disjoint **import graphs**, or a sibling's half-written code reds their run. A suite's shared step-definition file is one such graph: assignments landing in the same suite either run sequentially or each take their own step file.
- A **fit check** per assignment: it must comfortably fit one worker context window. An assignment that doesn't fit splits, adding a seam if the split needs one. A *slice* that doesn't fit goes back to planning to be split there.
- The **scenarios** per assignment, where the suite expresses its tests as scenarios. One glob for `**/*.feature` settles it, per suite, and hands §4 the file it matches against. Derived from the ticket's behavioural acceptance criteria, which are slice-wide and mechanism-free by construction: here each is realised at the seam that can observe it. A criterion spanning several assignments splits across the ones that can, plus a `@contract` scenario at each boundary it crosses, cited against the `contract-approval` record. A `@contract` scenario pins semantics the contract artifact cannot express: idempotent replay, retry thresholds, state transitions, ordering, emission obligations. One needing a mock response the artifact does not yet describe extends the artifact in the same slice. Where the union still leaves the composition itself unobserved, say so and raise it: that gap is the one thing earning a cross-service test, and it is the parent's call, not a worker's.

**A suite carrying no scenarios yet** keeps the repo's existing test idiom, and §4 runs plain cycles. Where the slice looks like a good place to adopt them, recommend it via `AskUserQuestion` and wait: on yes, the layout, runner wiring and shared step file become their own assignment, ordered first and sequential, since every later assignment reads the conventions it establishes. Once that lands the suite carries its own signal and later slices detect it.

Done when every seam has its assignments, and every assignment an order position, a parallel/sequential tag, a fit check, and its scenarios.

## 2. Model selection

Judge the difficulty of the work and **recommend** an implementer model via `AskUserQuestion`, offering alternatives + Other, with your reasoning. Wait for the pick.

Under **guarded**, recommend per assignment. Implementers lean cheaper, since they only make an existing expectation green, and assignments may run on different models. Re-recommend for one that turns out far harder or easier.

Under `**--solo**`, recommend once for the slice, a tier up: that worker designs the contract and derives its own expected values.

## 3. Agree the design

Per `tdd`: a seam is confirmed before its first test. Parent's job, before any cycle. How much gets confirmed depends on how much design the slice carries.

**Default**. Present the §1 seam list, confirm.

**Design gate**. Fires when the slice does any of: introduces a **new module**; adds an **internal seam** (one `contract-approval` doesn't already gate); or spans **≥4 hops across ≥2 existing modules**. These are the decompositions TDD can't reach. It drives what an assignment contains, never where the seam goes.

1. Parent drafts the design below.
2. **Red-team**: dispatch one reviewer worker (Agent, `general-purpose`), instructed to **load `codebase-design` itself** (subagents don't inherit the parent's loaded skills): flag every hop that only forwards arguments, every seam nothing actually varies across ("one adapter means a hypothetical seam"), and every cited existing symbol it can't find in the repo. Parent revises.
3. Present, and wait for the answer.

The design carries:

- **Seam signatures**. Real typed signatures, living as text in the review artifact; the repo stays untouched until §4. Seams only, never every hop. A cross-boundary seam cites its `contract-approval` record instead of re-litigating shape.
- **Module ownership**. Which module owns each new piece of behaviour.
- **Failure semantics**. Per seam: what throws, what catches it, what partial state survives.
- **One-way doors**. Each seam tagged reversible or expensive-to-change, so review attention lands on the ones that matter.
- **Flow**. Entry point through the hops, as a diagram, marked **illustrative and non-binding**: interior structure belongs to the refactor step, and a worker stays free to deviate from it.
- **Assumptions**. Every place the spec was silent and the parent chose.

**Resolution gradient:** the first seam in full detail, later seams coarse. A seam a later cycle teaches you is in the wrong place re-enters this gate; a seam never moves silently.

Done, on the default branch, when the seam list is confirmed. Done, when the gate fired, when the first seam has a confirmed signature, owning module, failure semantics and one-way/reversible tag, every later seam has at least the coarse version of those, and every assumption is either approved or replaced.

## 4. TDD loop, per assignment

The parent is the **loop driver**: it invokes the `tdd` skill itself to carry the red-green rules and anti-patterns, and carries adaptive state between assignments. Testing bias is covered by the **Bias guard** layers, not a per-assignment test auditor.

**guarded**, per assignment:

- Parent writes the contract and expected values (sourced from spec / worked example / known-good literal), the assignment's **scenario text** among them: it *is* an expected value, so a worker authoring its own would spend the anti-bias arm.
- Dispatch one implementer worker (Agent, `general-purpose`, chosen model) given only: the assignment, the contract + expected values, and an instruction to **load `tdd` and `coding-standards` itself** (same reason as §3 step 2). It works in **cycles**, preserving every assertion and injected expected value as given. If it judges the contract wrong, it stops and escalates to the parent.

`**--solo**`. One worker, dispatched once with the whole slice and its confirmed seams, writing every contract, test and implementation itself; no parent expected-value injection.

**When the §3 gate fired:** the signature and failure semantics of the assignment's seam are part of the contract the worker must hold. The flow diagram is not.

**Scenarios in the loop:** one scenario per cycle, red before green. A worker matches the suite's conventions against the feature file §1 hands it, reuses an existing step definition wherever one fits, and adds genuinely new steps to the suite's shared file.

**In-loop verification:** each cycle runs the worker's own test file, nothing wider. Project-wide typecheck and the full suite wait for §5. A wide check run under parallel workers reports a sibling's unfinished code as your own failure. An assignment that changes a contract artifact is the exception: it runs conformance for that artifact in-loop, since its truth is self-contained and no sibling can red it.

**Fit overflow:** a worker whose assignment turns out not to fit returns "doesn't fit" with a split suggestion instead of pushing through; parent splits it per §1.

An assignment is done when its tests are green; the loop is done when every assignment is done.

## 5. Fan-in check

Every assignment green, parent runs the project-wide checks the workers deferred: full typecheck, full test suite, and contract conformance where the repo can bring a provider up locally. Failures here are integration failures between assignments, the parent's to triage and dispatch, since no single worker can see them. Done when the tree is green.

## 6. Commit

Commit on a **feature branch** (create one if on the default branch, since no-mistakes validates committed history on a non-default branch).

## 7. Metrics

Record one metrics line per run. See `METRICS.md` for the schema and the mutation-proxy procedure.

## 8. Stop and hand off

Stop at the commit. Review, lint, push, PR and CI belong to `no-mistakes`. Report in one line that the work is ready, naming the branch, and stop there. The user drives `no-mistakes` themselves; it has gates only they should answer.

## Bias guard, three layers

Testing bias is caught in three places, so per-assignment test auditing is redundant:

1. **guarded expected-value injection**, §4.
2. **comprehensive-code-review Tests aspect**, downstream via no-mistakes (catches tautological / impl-coupled / weak-assertion tests).
3. **mutation-proxy metric**, §7.

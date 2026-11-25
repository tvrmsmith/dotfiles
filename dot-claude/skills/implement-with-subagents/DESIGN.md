# Seam design

Where a slice's seams go, when a slice carries enough design to need a gate, what that design spells out, and the scenarios that specify the slice at its seams.

**Load `codebase-design` before anything else.** Its vocabulary and seam rules govern this whole doc: the interface is the test surface, and one adapter means a hypothetical seam. Placing a seam where no test can live is the failure this catches.

## Seams

A **seam** is a public boundary inside the slice: the *location* where an interface lives. Place seams at public boundaries only, each one somewhere a test can cross.

**Start from the planned seams**: the Testing Decisions of the slice's spec, on the slice bead or on the parent spec its `## Parent` names, plus any wave design appended to the bead's `notes`. They are guidance, never a contract. Derive the seams they leave open, and move one when the code shows it belongs elsewhere. Each seam carries its **source**: planned, moved (with the reason) or derived.

A seam crossing a service or independent-deploy boundary cites its `contract-approval` record instead of re-litigating shape.

## Design gate

Fires when the slice does any of:

- introduces a **new module**;
- adds an **internal seam**, one `contract-approval` doesn't already gate;
- spans **≥4 hops across ≥2 existing modules**.

These are the decompositions TDD can't reach. The gate drives what an assignment contains, never where the seam goes.

### What the design carries

- **Seam signatures**. Real typed signatures, living as text in the review artifact; the repo stays untouched until code is written. Seams only, never every hop. A cross-boundary seam cites its `contract-approval` record.
- **Module ownership**. Which module owns each new piece of behaviour.
- **Failure semantics**. Per seam: what throws, what catches it, what partial state survives.
- **One-way doors**. Each seam tagged reversible or expensive-to-change, so review attention lands on the ones that matter.
- **Flow**. Entry point through the hops, as a diagram, marked **illustrative and non-binding**: interior structure belongs to the refactor step, and an implementer stays free to deviate from it.
- **Assumptions**. Every place the spec was silent and the designer chose.

**Resolution gradient:** the first seam in full detail, later seams coarse.

## Scenarios

A **scenario** is one behaviour of one assignment, written in Gherkin at the seam that can observe it. The scenarios are the slice's **spec**: the engineer approves every new or changed one before the build starts, and the build tests against what they approved.

### Deriving them

Derive them from the bead's behavioural acceptance criteria. Those are slice-wide and mechanism-free by construction, so each is realised here at the seam that can observe it. A criterion spanning several assignments splits across the ones that can, plus a `@contract` scenario at each boundary it crosses, cited against its `contract-approval` record. A `@contract` scenario pins semantics the contract artifact cannot express: idempotent replay, retry thresholds, state transitions, ordering, emission obligations. One needing a mock response the artifact does not yet describe extends the artifact in the same slice. Where the union still leaves the composition itself unobserved, say so and raise it: that gap is the one thing earning a cross-service test, and it is the orchestrator's call, never a worker's.

### Where they live

One glob for `**/*.feature` per suite the slice touches settles it.

- **A suite with `.feature` files**: each scenario follows that suite's conventions and belongs in the feature file the glob matched.
- **A suite without them**: the scenario is still Gherkin, marked **not persisted**. It never lands in the repo. It is the approved spec the suite's tests implement in their existing idiom.

### At the seam gate

The proposal carries each slice's new and changed scenarios in full, grouped by the feature file they belong in, or by suite marked not persisted. An existing scenario the slice keeps is referenced by name only. Scenarios only: step definitions and test code are the build's. Approval appends them to the bead's notes under a `Scenarios agreed in implement-in-waves run <id>:` header, beside the seams.

### In the build

The latest `Scenarios agreed` block in the bead's notes is the **starting set**. A bead carrying none, a slice built outside the waves, gets its scenarios derived as above.

- **Refine** freely, meaning unchanged: split a scenario, add example rows, reword steps to fit existing step definitions.
- **A new scenario, or a change of meaning**, proceeds unblocked and is **unapproved** until the engineer rules on it. Attended, present it and wait. Unattended, name it in the §8 report's `unapproved scenarios` field and in an `Unapproved-Scenario:` commit trailer, which slice-pipeline copies onto the pull request, so the engineer approves or rejects it at review before merge.
- **A suite without `.feature` files**: the tests implement the approved Gherkin in the suite's idiom, and the §8 report's `scenario map` names each test beside its scenario.

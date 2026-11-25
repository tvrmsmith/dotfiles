# Seam design

Where a slice's seams go, when a slice carries enough design to need a gate, and what that design spells out.

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

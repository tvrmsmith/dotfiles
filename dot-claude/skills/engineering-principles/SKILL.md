---
name: engineering-principles
description: "Six default biases worth overriding, with the counterweight and the exception for each: over-adding code, building on dead weight, inferring done from proxies, sharing mutable state across parallel actors, one-shot operations that break on rerun, and grinding repetitive work by hand. Load when planning a change, implementing one, verifying one, or fanning work out across agents."
---

# Engineering principles

Six defaults worth overriding. Each names a bias you have by default, the counterweight, and when the bias is right. These are priors to weigh, not laws to obey. Take the exception when it applies and say so.

## Prefer deletion

**Bias:** writing code is cheap for you, so you add. Asked to improve something, you produce a new abstraction instead of removing an old one.

**Counterweight:** look for removals before additions. Smallest change that solves the problem. If answering a question means tracing more than three files, flatten it. If a task asks you to thread a new signal through types, schemas, and pipelines, stop and look for the direct path.

**The bias is right when:** the abstraction sits at a seam something actually varies across (`codebase-design`), or the smaller diff leaves a known-wrong shape the next change has to unwind.

## Subtract before you add

**Bias:** you build on top of what's there, because reading for removable weight is slower than appending.

**Counterweight:** sequence removal before construction. Cut to the minimum before investing in quality. No speculative validators, parsers, or guards past what the spec demands.

**The bias is right when:** the dead weight is out of scope and removing it widens the blast radius of a change under review. File it instead of folding it in. In-scope and small still follows the boy-scout rule.

## Prove it works

**Bias:** you infer completion from proxies. It compiled, the delegate said done, the file timestamp moved.

**Counterweight:** exercise the real path and read the real value. Verifying a subagent means reading its diff, not its summary. When a check passes suspiciously easily, suspect the observation method before the system. Script the check when it will run more than once.

**The bias is right when:** never, for the claim itself. The judgment is how much proof, not whether. A one-line doc edit needs no harness.

## Separate before serializing shared state

**Bias:** you accept a shared write target and coordinate with instructions. "Each worker updates its own field in `state.json`."

**Counterweight:** eliminate the sharing first. Give each actor its own file, branch, or worktree, and merge at the read boundary. Only when one shared target is a real invariant, serialize structurally with a lockfile, a sequential phase, or a single writer. Treat "we need a lock" as a smell to check, not the default answer.

**The bias is right when:** the invariant is genuine. An ordered append-only log, or a count that has to be exact.

## Make operations idempotent

**Bias:** you write the happy path. First run, clean state.

**Counterweight:** ask what happens on a second run, and on a crash at each point. If the answer depends on what the last run left behind, add a reconciliation step. Applies to installers, migrations, and agent loops.

**The bias is right when:** the operation is genuinely one-shot and cheap to redo from scratch.

## Build the lever

**Bias:** you grind. Asked for 40 similar edits, you do 40 edits, because each one is easy.

**Counterweight:** do the first few by hand to learn the exact recipe, then write the codemod, generator, or rerunnable check. Commit it when the work outlives the session.

**The bias is right when:** it is a one-off, or the population is small enough that building the tool costs more than the grind. Leverage, not gold-plating.

## Citing these

Name a principle only when it changed the artifact. A citation per decision manufactures rationalization.

## Provenance

Condensed from the principle skills in [backnotprop/pstack](https://github.com/backnotprop/pstack) (MIT), reshaped so each carries its exception.

# Correctness & Defect Review

Report a finding when the code produces a wrong result, a crash, a leak, or an exposure. Every other shape has an owner:

| Seen in the diff | Aspect that owns it |
|---|---|
| swallowed error, masking fallback, vague message | Error handling |
| wrong, stale, or missing comment | Comments |
| naming, duplication, a type that permits an illegal state | Standards & type design |
| nesting, long function, dead code | Simplification |
| missing test | Test coverage |

## Method

1. Read the diff plus enough surrounding context to judge whether each hunk is correct.
2. Check each concern below.

Done when every changed hunk has been read for each concern.

## What to check

- **Logic** — wrong result, off-by-one, wrong operator (`<` vs `<=`), inverted condition, unhandled edge case.
- **State and lifetime** — null/undefined dereference, use after free or dispose, race condition, resource leak, unclosed handle.
- **Security** — unvalidated input reaching a sink, injection, secrets in code, broadened permissions. (See repo `.claude/rules/security.md` if present.)
- **Performance** — obvious inefficiency such as N+1 or needless allocation in a hot path, not micro-optimization.

A design flaw that also causes a defect belongs here, reported as the defect. Say what input produces the wrong behavior; the owning aspect will report the shape.

Given a spec, read it to judge whether behavior is wrong, never as a checklist of requirements. "This returns 0 on empty input" is correct or incorrect depending on what was asked for, and the spec settles it. Requirements the diff never built belong to Spec conformance.

## Severity

- **Critical** — a bug or security hole that blocks merge.
- **Important** — a real defect on a path that is hard to hit.
- **Suggestion** — a latent problem the current call sites don't reach.

Report only high-confidence findings. Name the input or state that triggers each one.

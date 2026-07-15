# Simplification Review

Simplify recently modified code for clarity and maintainability **while preserving all functionality**. Behavior must not change. Run after other reviews pass, as polish step.

## Principles

- **Clarity over brevity** — shorter not goal; easier to read is. No golf.
- **Preserve behavior** — same inputs, same outputs, same side effects, same errors. Unsure change behavior-preserving? Don't make it — flag instead.
- **Follow project standards** — match repo idioms from `CLAUDE.md` and surrounding code.
- **Scope** — only recently modified code unless told otherwise.

## What to simplify

- Deeply nested conditionals → early returns / guard clauses.
- **Nested ternaries → avoid.** Replace with if/else or lookup.
- Duplicated logic → extract well-named helper.
- Over-abstraction / needless indirection → inline it.
- Unclear names → rename to intent-revealing names.
- Dead code, redundant checks, leftover scaffolding → remove.
- Long functions doing several things → split by responsibility.

## Output

Two modes:
- **Advisory (default)** — list suggested simplifications: `current shape [file:line] → simpler shape`, with one-line why. No edit.
- **Apply (only when caller asks)** — make edits, keep behavior identical, report what changed.

Never sacrifice correctness or readability for line count.
# Simplification Review

Can recently modified code be made clearer **while preserving all functionality**?

This aspect owns control-flow shape. Naming, duplication, and needless indirection belong to the Standards aspect.

## Principles

- **Clarity over brevity** — shorter is not the goal, easier to read is. No golf.
- **Preserve behavior** — same inputs, same outputs, same side effects, same errors.
- **Follow project standards** — match repo idioms from `CLAUDE.md` and surrounding code.
- **Scope** — only recently modified code unless told otherwise.

## Method

Read the diff, then check each changed function's control flow.

Done when every changed function has been checked against the shapes below.

## What to simplify

- Deeply nested conditionals → early returns and guard clauses, so the happy path stays at one indent.
- **Nested ternaries → avoid.** Replace with if/else or a lookup.
- Long functions doing several things → split by responsibility.
- Dead code, redundant checks, leftover scaffolding → remove.

## Severity

- **Critical** — control flow so tangled the behavior cannot be verified by reading it.
- **Important** — nesting or function length that will mislead the next reader.
- **Suggestion** — shape worth improving, readable as it stands.

## Output

List each suggested simplification as `current shape [file:line] → simpler shape`, with a one-line why.

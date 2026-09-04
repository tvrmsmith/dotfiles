# Standards Review

Does the diff conform to how this code is supposed to be written? Two sources bind the answer: what the repo documents, and the `coding-standards:coding-standards` guidelines.

## Method

1. Find the repo's own standards: `CODING_STANDARDS.md`, `CONTRIBUTING.md`, `AGENTS.md`/`CLAUDE.md`, any `docs/` style guide.
2. Read the `coding-standards:coding-standards` skill. This aspect enforces its "Logic lives with its data", "Code smells", and "Make illegal states unrepresentable" sections, plus whatever its pointers route you to. Its "Errors" and "Comments" sections belong to their own aspects. A changed `.jsx`/`.tsx`, or JSX or a `use*` hook in a `.js`/`.ts`, fires the skill's React pointer: this aspect owns those findings, so read `react.md` and apply it.
3. Match every changed hunk against both sources, following the skill's own pointers wherever they fire.

Done when every changed hunk has been matched against both sources, and every file the skill routed you to has been applied to the code that triggered it.

**The repo overrides.** A documented repo standard always wins. Where it endorses something the guidelines would flag, suppress the finding.

**Leave linted rules alone.** Tooling that already catches it does not need review attention. Spend the attention on what only reading the code can find.

**A smell is a judgement call.** Name the guideline each finding breaches, and say what it costs this change. A smell you cannot tie to a cost is not a finding.

## Severity

- **Critical**: breaches a standard the repo documents, or a type whose construction lets a caller reach an illegal state. Name the illegal instance and the call site that can build it.
- **Important**: a smell clearly costing this change already, such as logic duplicated across hunks or one change scattered across many files.
- **Suggestion**: a smell that reads as a judgement call in context.

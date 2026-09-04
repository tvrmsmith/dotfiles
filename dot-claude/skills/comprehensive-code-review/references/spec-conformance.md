# Spec Conformance Review

Does the diff faithfully implement what the originating issue or spec asked for? Judge the change against the spec, not against your own view of what the code should do.

Your prompt carries a `Spec:` line: a bead id, a JIRA key, an absolute path, or "no spec exists".

**No spec, no review.** Report "no spec available" and stop. The commit messages and the diff are not a spec.

## Method

Read the spec, then the diff, then sort what you find into the three buckets below.

Done when every requirement in the spec has been traced to the diff, and every behavior in the diff traced back to a requirement.

## What to check

- **Missing**: requirements the spec asked for that are absent or only partly built.
- **Unasked**: behavior in the diff nobody requested. Scope creep, speculative extras.
- **Wrong**: requirements that look implemented, but the implementation reads incorrect against what the spec described.

Quote the spec line for every finding.

## Severity

- **Critical**: a requirement missing or implemented wrongly.
- **Important**: a requirement partly built, or unasked behavior with real blast radius.
- **Suggestion**: minor scope creep.

## Output

Where no spec existed, say so here rather than reporting clean.

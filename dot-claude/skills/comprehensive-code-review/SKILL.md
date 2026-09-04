---
name: comprehensive-code-review
description: Multi-aspect adversarial review of changed code. Use when asked to review a diff, a PR, or work before committing.
---
# Comprehensive Code Review

Review changed code across every applicable aspect below, then aggregate. Treat the diff as guilty until shown correct. Report only what survives scrutiny.

## 1. Scope

Default target: unstaged + staged changes (`git diff` and `git diff --cached`). PR exists (`gh pr view`) → use its diff. Honor explicit scope the caller gives.

Untracked files appear in neither `git diff` form. Run `git add -N` on every untracked path first, and record those paths for step 5.

Resolve scope into literal diff commands. Every agent gets those commands verbatim.

Resolve the **spec source** here too: the originating issue or PRD, as a bead id, JIRA key, or absolute path. Look in commit messages on the branch, then any path the caller passed, then `docs/`, `specs/`, `.scratch/` for a file matching the branch or feature. Found nothing → record "no spec exists".

Step 1 is done when the diff commands, the spec source, and any intent-to-add paths are all written down.

## 2. Pick applicable aspects

Caller named specific aspects (e.g. "review error handling and tests") → run only those. Else select from the changed files:

| Aspect | Reference | Required skills | Agent/model | Apply when |
|--------|-----------|-----------------|-------------|------------|
| Correctness & defects | `references/correctness.md` | — | — | always |
| Error handling | `references/error-handling.md` | `coding-standards:coding-standards` | `low-effort` | always |
| Comments | `references/comments.md` | `coding-standards:coding-standards` | `general-purpose/sonnet` | always |
| Test coverage | `references/tests-coverage.md` | — | — | test files or new logic changed |
| Test quality | `references/tests-quality.md` | `coding-standards:test-best-practices` | — | test files added or changed |
| Standards & type design | `references/standards.md` | `coding-standards:coding-standards` | — | always |
| Simplification | `references/simplification.md` | — | — | always |
| Spec conformance | `references/spec-conformance.md` | — | — | spec source resolved in step 1 |

Step 2 is done when every changed file has been matched against the Apply when column and the selected aspect list is written down.

## 3. Run reviews

An aspect naming an agent in its step-2 Agent/model cell uses it. For the rest, run
`cc-review-ab assign <ids>` once, passing their reference-file stems. Its first line is
`run<TAB><run id>`; keep that id for step 4. Every line after it is `aspect<TAB>agent`, or
`aspect<TAB>agent/model` where a model is pinned, in the same notation as the table.

Spawn one agent per aspect, all in **one batched message**. Give each agent the prompt below, substituting only `{ASPECT}`, `{SCOPE}`, `{ASPECT_FILES}`, and `{REQUIRED_SKILLS}`. Copy the rest verbatim.

- `{SCOPE}` — the literal diff commands from step 1, identical for every agent.
- `{ASPECT_FILES}` — the reference doc in the aspect's step-2 cell, as an absolute path.
- `{REQUIRED_SKILLS}` — that aspect's Required skills cell, comma-separated.

A Required skills cell of `—` drops line 1 and renumbers what's left.

Spec conformance and Correctness each take one extra line after `Scope:` — `Spec: <bead id, JIRA key, or absolute path from step 1>`. Spec conformance checks the diff against it. Correctness uses it only to tell a wrong result from an intended one. Every other aspect works from the diff alone.

```
Adversarially review this change for {ASPECT}. Treat the diff as guilty until shown correct.

Scope: {SCOPE}
1. Invoke these skills before you start and follow them over generic guidance: {REQUIRED_SKILLS}.
2. Read {ASPECT_FILES} and follow them exactly.
Follow through to any further skill or file the above tells you to load.
Issue independent tool calls in one message.
Report findings only, leaving the worktree exactly as you found it.
Report only what survives scrutiny.
Open with a one-line judgment for the aspect, saying "no findings" explicitly when it ran clean.
Label every finding by severity and use this exact format:
  `severity — description [file:line] → concrete fix`
Severity: Critical, Important, or Suggestion, calibrated by the definitions in the reference doc.
```

A report that stops mid-sentence, or ends by saying the rest was held back, is truncated, and its
missing findings also undercount step 4's log. Message that agent by the name you spawned it under
and ask for only the findings it has yet to deliver.

Step 3 is done when every agent in the batch has returned a report that runs to its end.

## 4. Aggregate

Merge every aspect except Spec conformance into one report, deduped, grouped by the severity labels above.

Present **Spec conformance** as its own section, un-merged. Include that section every time: where no spec existed, the section says so. Every aspect selected in step 2 appears in the report, with "no findings" stated explicitly where it ran clean. Close with a recommended action order.

Log each aspect:
`cc-review-ab record <run id> <aspect> <critical> <important> <suggestion> --agent <spawned name>`,
writing the aspect as `<stem>=<agent/model>` for the ones step 3 never sent to `assign`.
Count what that agent reported, before deduping against other aspects. `--agent` reads the tokens
and seconds off that subagent's transcript, so spawn each agent under a name unique within the
session and pass that same name here.

Step 4 is done when every aspect selected in step 2 appears in the report and has been logged.

## 5. Restore scope

Recorded intent-to-add paths in step 1 → run `git reset -- <those paths>`.

Step 5 is done when the index is back to how step 1 found it.

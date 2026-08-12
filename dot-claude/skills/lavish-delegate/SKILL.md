---
name: lavish-delegate
description: Delegate a lavish HTML review to a subagent instead of invoking `lavish` directly. Use when sizing whether something is worth an artifact, when dispatching the review, and when a lavish subagent reports back.
---

# Delegating a lavish review

A lavish artifact costs ~20k tokens to write and more per revision round. The
subagent holds the HTML; the main thread holds the decisions.

## Is it worth an artifact

Delegate when the artifact carries three or more sections, a diagram, or a comparison
the reader must scan. Below that, answer in prose.

Keep the review in this thread when its feedback drives edits you must make here
immediately — the hand-off back and forth then costs more than the artifact saves.

## Dispatch

Spawn one **named** subagent — round two reaches the same agent through
`SendMessage`, artifact and design choices still in its context.

## The brief

Non-discoverable only: the decision content to visualize, the audience, and any
constraint that lives in this conversation. Repo conventions, the `lavish` skill,
ticket text — it finds those itself.

Paste this verbatim; the subagent cannot see this file:

> Build the artifact with the `lavish` skill. Run `lavish-axi poll` with the Bash
> tool's `run_in_background: true`. When the review settles, run
> `lavish-axi end <html-file>` and report back under exactly these headings, with
> `none` where a heading is empty:
>
> - **Decisions** — what the user approved, rejected, or changed
> - **Deltas** — where the reviewed plan now differs from what was sent in
> - **Open questions** — anything deferred or left ambiguous
> - **Artifact path** — for reopening the review

## Landing the report

Relay before you act. Every **Decision** and **Delta** reaches the user in the
subagent's own terms; every **Open question** gets asked or answered here.

Landed when all four sections have been relayed or applied and the plan in this
thread matches the deltas. Too thin to do that — `SendMessage` the subagent.

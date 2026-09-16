---
name: bd-decision-records
description: >
  Where a bd decision or spike bead's output lives: `design` holds the record, comments
  hold the trail. Use when recording a decision on a bead, amending one, or closing a
  decision or spike bead.
allowed-tools: "Read,Bash(bd:*),Bash(git:*)"
---

# Decision records on bd beads

A `decision` or `spike` bead produces output that downstream work must consume. Two words
decide where each piece goes.

The **record** is what is true now: the chosen direction, complete and self-contained. It
lives in `design`, one field, always current.

The **trail** is how you got there: alternatives rejected, grilling, approval evidence
stamped with a time. It lives in comments, append-only.

A reader who needs the decision reads `design` and stops. A reader auditing how it was
reached reads the trail.

## Where each piece goes

| Field | Holds | Mutability |
|-------|-------|------------|
| `description` | the question the bead answers | fixed at creation |
| `design` | the record | rewritten whole on every amendment |
| comments | the trail | append-only, never authoritative |
| `close_reason` | what shipped and where: prototype SHA, vocabulary SHA, PR | written once |
| parent's authored text | the gist plus a pointer, one per child | grows as children close |

## Amending

**An amendment rewrites `design` and adds a comment saying what changed and why.**

Never the reverse. A comment that corrects `design` splits the truth in two, and the next
reader has to diff nine comments in order to find which one won. `--design-file` replaces
wholesale, so regenerate the full document rather than patching it. That cost is the point:
it forces the record to stay complete.

Comment bodies are not indexed by `bd search` in current builds. A decision reachable only
by `bd show <id> | grep` is a decision nobody will find.

## Closing a decision or spike bead

Every item is checked by `bd-close-guard.sh` on `bd close`.

1. **Type it right.** Research is `spike`, a decision is `decision`, neither is `task`.
2. **Fill `design`** with the record.
3. **Commit prototypes** to one directory `prototypes/<bead-id>/`, so the bytes outlive an
   ephemeral worktree.
4. **Record the pointer by SHA**: `Prototype: <sha>:prototypes/<bead-id>/`. The SHA survives
   a branch rename or delete; name the branch alongside it for humans.
5. **Promote to the parent**: copy the decision gist and the same pointer into the parent
   bead, so the consumer is routed through the result.

A text-only mock may inline into `design` instead of being committed.

## Repo-specific rules

Some repos add their own conventions on top of this: which labels signal readiness, where
vocabulary ships, which specs flow back upstream. Read that repo's
`docs/agents/issue-tracker.md` for them.

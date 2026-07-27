---
name: imr-standup
description: Standup status update for Meridian.IMR, built from your GitHub PRs and beads issues.
disable-model-invocation: true
---

# Meridian.IMR standup update

Produce a scannable status update covering a work window, sourced from GitHub PRs and the
beads tracker. Reader is the team in standup, not a code reviewer. Deliver it as markdown in
chat — no file, no clipboard. Assumes macOS (BSD `date`).

## 1. Fix the window

Default: **since the last standup**. Monday looks back to Friday, every other day to yesterday:

```bash
[ "$(date +%u)" -eq 1 ] && BACK=3 || BACK=1
date -u -v-${BACK}d +%Y-%m-%dT00:00:00Z
git config user.name
```

If the user names a window ("since Wednesday", "this sprint"), use theirs instead.

**Shell state does not survive between Bash calls.** Read both values off this one call, then
paste them literally into every command below — a `$WINDOW_START` that expands to empty turns
each filter into a match-everything, which looks like a successful run. If either comes back
empty, stop and fix it before gathering.

## 2. Gather

**PRs — the spine of the report.** Run the list first, then fan out `gh pr view` across the
results in parallel. GitHub identity comes from `@me`, not the git name.

```bash
gh pr list --author "@me" --state all --limit 100 \
  --json number,title,state,createdAt,updatedAt,mergedAt \
  --jq '.[] | select(.updatedAt > "2026-07-24T00:00:00Z") | "\(.number) [\(.state)] \(.mergedAt // .createdAt) \(.title)"'
```

Merged PRs need a body to describe behavior from — a title alone produces bullets that just
restate the title:

```bash
gh pr view <N> --json title,body
```

Open PRs need the state that decides the next step. `mergeStateStatus: DIRTY` means conflicts,
not a broken build. `statusCheckRollup` mixes two shapes — check runs carry `conclusion`, commit
statuses carry `state` — so match both or failing statuses vanish and the PR reads as clean:

```bash
gh pr view <N> --json title,isDraft,mergeStateStatus,reviewDecision,statusCheckRollup \
  --jq '{title,isDraft,mergeStateStatus,reviewDecision,
         failing:[.statusCheckRollup[]?
                  | select(.conclusion=="FAILURE" or .state=="FAILURE")
                  | .name // .context]}'
```

**Beads.** PR titles usually carry the bead id in parens (`(emr-5rkj.4)`). Filter by assignee so
the shared team DB doesn't leak in — the assignee is a display name (`"Trevor Smith"`), matching
`git config user.name`:

```bash
bd list -a "Trevor Smith" --status closed --closed-after 2026-07-24T00:00:00Z --flat
bd list -a "Trevor Smith" --status open,in_progress --flat
```

Zero closed beads over a window with merged PRs means the assignee string is wrong, not that
nothing landed — confirm it against a `bd show` on any bead cited in a PR title.

From the open/in_progress list, keep only what feeds Next steps: beads touched during the window
and the direct successors of the work that landed. The rest of the backlog stays out.

Then:

```bash
bd show <id>                # run on every bead kept from that filter, plus every closed one
bd list --parent <epic-id>  # only when a kept bead sits under an epic and you need its siblings
```

**Commits** are a memory aid only — `git log --author="Trevor Smith" --since=2026-07-24` to recall
what a PR contained.

**Done when:** every open PR has its `mergeStateStatus` and `reviewDecision` recorded, every kept
bead has been through `bd show`, and every merged PR has a body or bead detailed enough to write
its bullet from.

## 3. Write it

Three sections, exactly these headings. Title carries the window — weekday range for the default
(`# Standup — Fri → Mon AM`), the user's own phrasing when they named one.

```markdown
# Standup — <window>

## Progress since last update
<N> PRs merged / <N> beads closed, <one-clause theme>.

- **<Area>** (#PR): what it does now, in the reader's terms. One or two sentences.
- **<Area>** (`<bead-id>`): same shape, for work with no PR to point at.
- ...

## Next steps
1. <most imminent — usually landing the open PR>
2. ...

## Blockers
<blocker list, or: None. All self-clearable.>
```

### Content rules

- **Group by area of work, not by PR.** Two PRs on the same feature share one bullet carrying both
  numbers. A PR folded into another's squash gets noted as such.
- **Cite work by PR number, or bead id where there's no PR.** Nothing else from git reaches the
  page: no branch names, SHAs, commit subjects, local working-tree state, or housekeeping section.
- **Describe behavior, not diffs.** "Close from any active state, reason captured as structured
  data" — not "added `ReferralCloseContext` record to the Application layer".
- **One or two sentences per bullet.** If a bullet needs three, it's two bullets or the detail
  doesn't belong.
- Lead with feature work. Dev-stack and tooling changes collapse into one trailing bullet.

### Blockers

A blocker is **something the user cannot clear alone** — waiting on another team, an access grant,
an unmerged dependency owned by someone else, an unanswered decision. Merge conflicts, failing CI
on the user's own PR, and unfinished work are not blockers; if nothing qualifies, say so rather
than promoting one of those. Known-but-not-yet-urgent dependencies (an unimplemented platform
capability a future step needs) go in Next steps with the "not urgent yet" framing.

**Done when:** every merged PR in the window appears in exactly one Progress bullet, every open PR
appears in Next steps or Blockers, every bead-only item in the window appears in one bullet, and
every bullet obeys the content rules above.

## 4. Iterate

When the user asks for a change, re-render the whole update rather than describing the edit.

---
name: pr-review-loop
description: Converge a PR against its own automatic Claude bot review instead of running a review yourself, attended or unattended. Triggers on "PR review loop", "loop the Claude PR review", "unattended PR review".
---
# PR Review Loop

Converge a PR against its own automated Claude reviewer. Instead of running a review command yourself, read the findings the `@claude` GitHub Actions workflow already posted on the PR, triage, fix in a subagent, commit + push, reply to and resolve the addressed threads, then post `@claude` to re-trigger the bot. Poll for the fresh review and repeat until it comes back clean, iterations cap out, or the wait times out.

This is the GitHub-specific, side-effecting sibling of `review-loop`: it commits, pushes, and comments on a live PR. Use `review-loop` for a local `git diff`; use this when a PR already has a Claude bot review to converge against.

## 1. Parse arguments

Arguments are free-form natural language. Extract optional elements; fall back to defaults when absent:

| Element | Default | Examples |
|---------|---------|----------|
| PR | current branch's open PR (`gh pr view`) | "PR 42", a PR URL |
| Max iterations | `4` | "max 6", "3x" |
| Poll timeout (per re-review) | `15m` | "wait up to 30m" |
| Poll interval | `30s` | "poll every 60s" |
| Focus | none | "focus on error handling" |
| Model preset | none (recommend + confirm each iteration) | "model=sonnet", "use opus", "haiku for fixes" |
| Mode | attended | "unattended", "--unattended", "no human in the room" |

**Model preset:** when set, skip 3e's confirm prompt and apply that model to every iteration's fixes.

Focus, when set, is appended as guidance to the `@claude` re-request (step 3g) and biases triage (step 3c).

After parsing, echo the resolved config in one line before anything else, so a misparse is caught immediately:

```
PR: <#/url> · Max: <n> · Poll: <interval>/<timeout> · Focus: <focus or "none"> · Model: <preset or "per-iteration"> · Mode: <attended|unattended>
```

### 1a. Unattended mode

Unattended means no human is in the room, so the loop takes a documented default at every gate and runs to a verdict the caller can read. A pipeline node (an Archon AI node listing this skill under `skills:`) is the caller this exists for.

**Take the default and keep going.** Each of the four gates states its own unattended default where the gate lives, so the model picks nothing. The gates are 3a bot author, 3d ambiguous findings, 3e fix model, 3i poll timeout. `AskUserQuestion` is attended-only. Unattended, reaching for it hangs the pipeline node until its own timeout kills the run.

**The verdict** is the last thing the run prints, a fenced JSON object and nothing after it, so an Archon node's `output_format` validates it and a downstream node reads `$<node>.output.clean`:

```json
{
  "clean": false,
  "verdict": "deferred-only",
  "pr": "https://github.com/<owner>/<repo>/pull/<n>",
  "head_sha": "<short sha of the last pushed commit, or null>",
  "iterations": 2,
  "fixed": 7,
  "deferred": [
    { "finding": "src/auth.ts:42 · widen the retry window", "reason": "ambiguous, no human in the room" }
  ],
  "stop_reason": "one sentence, human-readable"
}
```

`stop_reason` restates `verdict` in one sentence. It may add the concrete detail (a sha, a count, a run id) but must never name a reason the enum below does not cover.

`clean` is true only for `verdict: "clean"`, the one outcome meaning the bot came back with nothing actionable. Every other value names a section 4 stop condition:

- `deferred-only`, progress stalled on findings nobody was there to approve.
- `max-iterations`, the cap ran out.
- `timed-out`, the bot never posted a fresh review.
- `no-review`, there was no bot review to converge against.
- `blocked`, the loop could not run, from no open PR or a push that `git-ssh-fix` and a retry did not fix.
- `failed`, a tool call the loop depends on kept failing.

**Tool failures are never domain outcomes.** Any `gh` or `git` command that still fails after one retry ends the run with verdict `failed`. Never read a non-zero exit as an empty result, so a failed `gh api` is not "no bot post qualifies" and a failed `gh pr comment` is not a review that never landed. Every unattended exit path, including one you did not plan for, prints the verdict object as its last output.

Write the same object to `$ARTIFACTS_DIR/pr-review-loop.json` once, at exit, when that variable is set, so the verdict survives the node's output being truncated. Run `mkdir -p "$ARTIFACTS_DIR"` first; if the write still fails, print a one-line warning before the JSON and carry on.

## 2. Auth and directory awareness

Follow the global git/`gh` rules in `~/.claude/CLAUDE.md`. If a push fails with `Permission denied`, invoke the `git-ssh-fix` skill and retry.

**Unattended:** when there is no open PR to converge against, stop before iteration 1 with verdict `blocked`.

Resolve `<owner>/<repo>` and the PR number once up front (`gh pr view --json number,headRefName,url,headRepositoryOwner,headRepository`). Reuse them for every `gh` / `gh api` call in the loop.

## 3. The loop

Repeat each iteration until a stop condition (section 4) holds. Track the iteration number against max.

### 3a. Fetch the Claude bot review (main thread, `gh`)

Pull the newest Claude-bot review on the PR from **both** sources:

- PR reviews and their inline comments:
  `gh api --paginate repos/<owner>/<repo>/pulls/<n>/reviews` and `gh api --paginate repos/<owner>/<repo>/pulls/<n>/comments` (`--paginate` so a large PR's comments aren't truncated at the 30-item default page).
- Issue comments:
  `gh pr view <n> --json comments`.

**Bot author detection.** Match the author login against `claude[bot]` or `github-actions[bot]` (author type `Bot`). On the first iteration, if no author matches or the match is ambiguous, inspect the PR once and confirm the correct bot author with the user via `AskUserQuestion` before proceeding. Remember the confirmed author for the rest of the run.

**Unattended default:** prefer the newest `Bot` author whose login is `claude[bot]` or `github-actions[bot]`, and remember it for the rest of the run. Only when no login matches, fall back to the newest `Bot` post carrying review structure, so a PR whose reviewer posts under another login still converges. When nothing qualifies, stop with verdict `no-review` rather than converging against a human's comment or another tool's findings. That holds on every iteration, not only iteration 1; on a later iteration the remembered author is the only one eligible, and a landed review from anyone else is not the review.

**Iteration 1** uses the review already on the PR — the automatic one; no trigger is needed. Later iterations use the review that landed in step 3i.

**Selecting "the review".** Take the newest bot-authored review/comment that carries actual review content — see the landed-vs-acknowledgment heuristic in 3i.

### 3b. Parse to condensed findings

Reduce the fetched review to a condensed list, one line per finding:

```
path:line · severity · problem · suggested fix
```

Keep raw review bodies out of the main thread beyond this reduction. Retain each finding's originating review-comment id (for replying/resolving in 3g).

### 3c. Triage

Classify each finding:

- **Clear** — high-value, unambiguous. Auto-approved for fixing; not surfaced.
- **Ambiguous / unnecessary** — risky, low-value, or a judgment call. Must surface to the user.

Skip findings the user already deferred (see section 4 state).

### 3d. Decision gate

If there are any ambiguous/unnecessary findings this iteration, present them with `AskUserQuestion` (group related findings; split into multiple sequential questions if they exceed one question's capacity; each option is fix or skip). Clear findings are NOT shown. The approved set = clear findings + ambiguous findings the user chose to fix. Findings the user declined are recorded as deferred. If every finding this iteration is clear, skip the question and go straight to fix dispatch (3e).

**Unattended default:** fix the clear findings and defer every ambiguous one, each recorded with the reason `ambiguous, no human in the room`. The loop declines a judgment call nobody is present to make rather than guessing it, and the verdict's `deferred` list is where the caller picks it back up. When that leaves no approved set at all, skip 3e, 3f, 3h and 3i; do 3g, print the 3j iteration summary with `pushed nothing`, and stop immediately with verdict `deferred-only`.

### 3e. Fix dispatch

**Model selection (each iteration, before dispatch).** Pick the model that will apply this iteration's approved fixes. Routing policy:

- Default **Sonnet** (`sonnet`). Escalate to **Opus** (`opus`) for subtle logic, cross-file refactors, or correctness/security judgment. **Haiku** (`haiku`) only for purely mechanical fixes (renames, typos, formatting) — sparingly. Never **Fable**.

If a model preset was parsed (step 1), use it and skip the prompt. Otherwise present the recommendation with `AskUserQuestion`: recommended model first, labelled `(Recommended)`, then the other allowed models so the choice can be overridden. **Ask every iteration** — each iteration's fixes differ and may warrant a different model. When a large batch is split across parallel subagents whose complexity differs materially, recommend per-batch rather than one model for the whole iteration.

**Unattended default:** apply the routing policy above as the decision, per iteration, with no prompt. A parsed model preset still overrides it.

Apply the approved findings via subagent(s), dispatched with the selected model via the Agent tool's `model` parameter:

- **Small set** → a single fix subagent takes the whole batch, applies edits, reports what changed.
- **Large set** → split findings into per-file / per-area batches and dispatch one subagent per batch, in parallel only where edits cannot conflict (never two subagents editing the same file at once).

Deferred findings are NOT fixed.

### 3f. Commit and push

- **One commit per iteration:** stage this round's fixes and commit as a single commit, message via the `caveman:caveman-commit` style.
- Push to the PR branch (auth and retry per §2).

**Unattended:** a push that `git-ssh-fix` and one retry did not fix stops the run with verdict `blocked`, emitting the verdict object with the counts so far and the unpushed local commit sha in `stop_reason`, since that commit exists only in this worktree.

Capture the pushed short SHA for the iteration summary and the thread replies.

### 3g. Reply to comments and resolve threads

**Every inline review thread this iteration gets a reply and ends resolved** — a decision was made on each one, so none is left open. Leave a thread unresolved only when the user explicitly asks for it to stay visible.

- **Fixed** → post a very concise reply on the thread (e.g. `Fixed in <sha>.`), then resolve the thread.
- **Deferred** → post a concise reply stating the decision and the reason it was not fixed, then resolve the thread. Deferring is an answer, not an open question; the reply is the record, and the final report (section 5) carries the deferral forward.
- **No action needed** (the bot confirmed correct behaviour or filed an informational note) → resolve the thread; a reply is optional.

Before moving to 3h, re-run the `reviewThreads` query and confirm every thread reports `isResolved: true` except any the user asked to keep open. An unresolved thread left behind is a defect in this step, not a signal.

Mechanics: inline review comments live in review threads. Reply with
`gh api repos/<owner>/<repo>/pulls/<n>/comments -f body=... -F in_reply_to=<comment_id>`.
Resolve with the GraphQL `resolveReviewThread` mutation; thread ids come from the
`pullRequest(number: <n>) { reviewThreads(first: 100) { nodes { id isResolved comments(first: 1) { nodes { databaseId } } } } }`
query via `gh api graphql`. General (non-thread) issue comments have no resolve concept — a reply is optional and skipped by default.

### 3h. Re-request review

Post a PR comment containing `@claude` (append focus guidance if set), e.g.:

```
gh pr comment <n> --body "@claude please re-review — pushed fixes for the findings above."
```

Record the trigger comment's `createdAt` timestamp.

### 3i. Poll for the fresh review

Poll for a **new** bot review/comment whose `createdAt` (or review `submittedAt`) is newer than the trigger timestamp, every poll interval until the poll timeout.

**Landed vs. acknowledgment heuristic.** A post-trigger bot comment counts as the review only when its body carries review structure (findings, a verdict, or inline review comments) — not a bare acknowledgment or in-progress placeholder. The bot commonly edits one comment in place (ack → review), so apply a short settle delay (a couple of poll intervals with no change, or the comment gaining review structure) before treating it as final.

- Review lands → continue to 3j, which counts the iteration, evaluates the stop conditions, and routes back to 3a. Never jump straight back to 3b; that skips the cap and the loop never ends.
- **Poll timeout** → present `AskUserQuestion`: (a) keep waiting — extend by the timeout again, (b) stop and report, (c) check the Actions run (`gh run list` / `gh run watch`), then re-present this gate once the run finishes. Interactive; never silently abort.

**Unattended default:** on the timeout, check the Actions runs once with `gh run list --event issue_comment --json databaseId,status,createdAt`. A run whose `createdAt` is at or after 3h's trigger timestamp and whose `status` is `queued` or `in_progress` buys one extension of the poll timeout. Anything else (no run matches, or the matching run already finished without posting a review) stops the loop with verdict `timed-out`. A query that fails buys no extension either, so it stops the loop with `timed-out` too, the one place a failing command reports something other than `failed`, because the poll had already timed out before the query ran. One extension per iteration, never two, so a stuck bot costs the pipeline a bounded wait.

### 3j. Iteration summary

After each iteration, print one line:

```
Iter <i>/<max>: <total> findings · <fixed> fixed · <deferred> deferred · pushed <sha or "nothing">
```

Then evaluate stop conditions (section 4). If none hold, start the next iteration at 3a using the review that landed in 3i.

## 4. Stop conditions and state

Evaluate these in order and take the first that holds, so one run has exactly one verdict. Always evaluate the review that landed in the final iteration before the cap.

1. The poll timed out AND the timeout gate resolved to stop (the user's choice attended, 3i's default unattended) → `timed-out`.
2. Only already-deferred findings remain, so no progress is possible → `deferred-only`.
3. Clean review: after removing the running deferred set the finding set is empty AND the deferred set is empty → `clean`. Remove the deferred set first, since 3a re-fetches the full review each time and the bot re-reports deferred items every round.
4. Iteration count reaches max iterations → `max-iterations`.

Unattended only, the run also stops the moment a step reaches one of these, whichever iteration it happens on: no bot review to converge against (3a) → `no-review`; no open PR (§2) or a push `git-ssh-fix` and a retry did not fix (3f) → `blocked`; a `gh` or `git` failure per 1a → `failed`.

**State across iterations:** maintain a running set of deferred findings. Once a finding is deferred, by the user attended or by 3d's default unattended, never surface it again in this run. Only genuinely new findings trigger the decision gate on later iterations.

## 5. Final report

Unattended, the report is the 1a verdict object and nothing else. Attended, print:

- Total iterations run.
- Total findings fixed.
- Deferred list, each with the reason it was not fixed.
- Stop reason (max reached / clean review / only deferred remain / user stopped at timeout gate).
- PR link.

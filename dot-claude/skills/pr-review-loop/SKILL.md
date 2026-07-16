---
name: pr-review-loop
description: Converge a PR against its own automatic Claude bot review instead of running a review yourself. Triggers on "PR review loop", "loop the Claude PR review".
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

**Model preset:** when set, skip 3e's confirm prompt and apply that model to every iteration's fixes.

Focus, when set, is appended as guidance to the `@claude` re-request (step 3g) and biases triage (step 3c).

After parsing, echo the resolved config in one line before anything else, so a misparse is caught immediately:

```
PR: <#/url> · Max: <n> · Poll: <interval>/<timeout> · Focus: <focus or "none"> · Model: <preset or "per-iteration">
```

## 2. Auth and directory awareness

Follow the global git/`gh` rules in `~/.claude/CLAUDE.md`. If a push fails with `Permission denied`, invoke the `git-ssh-fix` skill and retry.

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

### 3e. Fix dispatch

**Model selection (each iteration, before dispatch).** Pick the model that will apply this iteration's approved fixes. Routing policy:

- Default **Sonnet** (`sonnet`). Escalate to **Opus** (`opus`) for subtle logic, cross-file refactors, or correctness/security judgment. **Haiku** (`haiku`) only for purely mechanical fixes (renames, typos, formatting) — sparingly. Never **Fable**.

If a model preset was parsed (step 1), use it and skip the prompt. Otherwise present the recommendation with `AskUserQuestion`: recommended model first, labelled `(Recommended)`, then the other allowed models so the choice can be overridden. **Ask every iteration** — each iteration's fixes differ and may warrant a different model. When a large batch is split across parallel subagents whose complexity differs materially, recommend per-batch rather than one model for the whole iteration.

Apply the approved findings via subagent(s), dispatched with the selected model via the Agent tool's `model` parameter:

- **Small set** → a single fix subagent takes the whole batch, applies edits, reports what changed.
- **Large set** → split findings into per-file / per-area batches and dispatch one subagent per batch, in parallel only where edits cannot conflict (never two subagents editing the same file at once).

Deferred findings are NOT fixed.

### 3f. Commit and push

- **One commit per iteration:** stage this round's fixes and commit as a single commit, message via the `caveman:caveman-commit` style.
- Push to the PR branch (auth and retry per §2).

Capture the pushed short SHA for the iteration summary and the thread replies.

### 3g. Reply to comments and resolve threads

For each inline review-thread comment acted on this iteration:

- **Fixed** → post a very concise reply on the thread (e.g. `Fixed in <sha>.`), then resolve the thread.
- **Deferred** → post a concise reply noting the reason, and leave the thread unresolved so it stays visible.

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

- Review lands → return to 3b to parse it for the next iteration.
- **Poll timeout** → present `AskUserQuestion`: (a) keep waiting — extend by the timeout again, (b) stop and report, (c) check the Actions run (`gh run list` / `gh run watch`), then re-present this gate once the run finishes. Interactive; never silently abort.

### 3j. Iteration summary

After each iteration, print one line:

```
Iter <i>/<max>: <total> findings · <fixed> fixed · <deferred> deferred · pushed <sha>
```

Then evaluate stop conditions (section 4). If none hold, start the next iteration at 3a using the review that landed in 3i.

## 4. Stop conditions and state

Stop the loop when ANY holds:

- Iteration count reaches max iterations.
- The fetched review returns no actionable findings (clean review) — evaluate this AFTER removing the running deferred set, since 3a re-fetches the full review each time and the bot will re-report deferred items every round.
- The only findings left are ones the user already deferred (no progress possible).
- The poll times out AND the user chose "stop" at the timeout gate.

**State across iterations:** maintain a running set of deferred findings. Once the user defers a finding, never surface it again in this run; only genuinely new findings trigger the decision gate on later iterations.

## 5. Final report

On exit, print:

- Total iterations run.
- Total findings fixed.
- Deferred list, each with the reason it was not fixed.
- Stop reason (max reached / clean review / only deferred remain / user stopped at timeout gate).
- PR link.

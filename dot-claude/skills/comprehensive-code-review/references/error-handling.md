# Silent Failure & Error Handling Review

Zero tolerance for silent failure. Silent failure = error swallowed, hidden, or turned into misleading success. Worse than crash — hide bugs in production.

## Method

Scan diff for every error path: catch blocks, fallbacks, optional chaining over risky calls, default returns, ignored return values.

## Red flags

- **Swallowed exceptions** — empty catch, catch that only debug-logs and continues, catch returning fake-success value.
- **Fallbacks that mask failure** — return empty/default/cached data when real operation failed, no failure signal.
- **Vague error messages** — "something went wrong", no context, no identifiers, no original error. Message must say what failed, enough detail to act.
- **Lost error context** — re-throw without cause, catch broad types that hide unrelated errors.
- **Unchecked results** — ignored return codes/Result values, unawaited promises/tasks.
- **Overly broad catches** — `catch (Exception)` around wide block, hides errors not meant to handle.

Fold in repo's own logging/error conventions (from `CLAUDE.md`) — use project logger and error-id patterns, not generic ones.

## Severity

- **CRITICAL** — error fully swallowed; failure invisible in production.
- **HIGH** — failure logged too quietly or masked by fallback; hard to detect.
- **MEDIUM** — weak error message, lost context, broad catch.

## Output

Per finding: `severity — what's swallowed/masked [file:line] → how to surface it (throw, propagate Result, log at right level, enrich message)`. Errors loud, contextual, propagated — not hidden.
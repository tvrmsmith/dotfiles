# Silent Failure & Error Handling Review

Every error path the diff adds, changes, or leaves unhandled.

## Method

1. Read the "Errors" section of the `coding-standards:coding-standards` skill. Those are the guidelines this aspect enforces.
2. Scan the diff for every error path: catch blocks, fallbacks, optional chaining over risky calls, default returns, ignored return values.
3. Match each path against the guidelines.

Done when every error path in the diff has been matched, including the paths the diff leaves implicit by not handling them.

## Severity

- **Critical** — error fully swallowed; the failure is invisible in production.
- **Important** — failure logged too quietly or masked by a fallback; hard to detect.
- **Suggestion** — weak error message, lost context, broad catch.

Every finding names the fix that surfaces the error: throw, propagate a Result, log at the right level, or enrich the message.

# 0002: Agents act as Trevor, with one classic token per account synced from 1Password

Status: accepted, 2026-11-23

## Context

The gh shim split every call into three tiers (read, pr-write, write), each with
its own fine-grained token, and asked 1Password to approve the write tier. Pushes
went over SSH through 1Password's SSH agent, fetches over HTTPS with the read
token. The point was that no agent could merge or push to main without an
approval.

Trevor decided agents may push and merge pull requests as him, with no gate.
Once nothing is gated, the tiers, the approvals and the second credential type
only cost prompts and code. A separate GitHub machine account for agents was
also considered and dropped as more process than the risk calls for.

## Decision

Each GitHub account gets one classic token, kept in a 1Password vault of its
own. A read-only 1Password service account on that vault lets
`dot-local/bin/gh-token-sync` copy each token into the OS keyring (service
`gh-token`, keyed by owner) every hour with no prompt, so a rotation in
1Password reaches the machine within the hour. On Linux a systemd user timer
runs it, with the service account token as a systemd credential encrypted for
the user (`extras/gh-token-sync/`). A machine without the sync, such as the work
laptop, gets its token once by hand with `gh-keyring set gh-token <owner>`.

The gh shim keeps one job: pick the token for the repo's owner and run the real
gh with it. git uses the shim as its HTTPS credential helper and reaches GitHub
over HTTPS only, so neither account needs an SSH key. Commit signing with
`~/.ssh/git-sign-personal` is separate from authentication and stays.

## Consequences

- Anything running as Trevor, an agent or a bad package install, can push,
  merge and delete as him, with admin rights on his own repos. That is the
  accepted cost.
- The service account token can read the agents' vault and nothing else. It can
  never be given Personal, Private or the default Shared vault.
- Gone: the read and pr-write tiers, the GraphQL read classifier, the 1Password
  write path and its timeout, the escalation log, `gh-pr-checks` (classic
  tokens keep the Checks permission), `extras/gh-readonly-tokens.sh`, the
  write-tokens map, the 1p-retry-band skill, and the SSH push rewrite with the
  GitHub blocks in `dot-ssh/config`. ADR 0001's port triggers that name these
  pieces no longer apply; the shim stays bash.
- Owner picking stays while personal and work accounts share a machine. When
  the work laptop stops holding the personal account, the shim can go and the
  real gh's own login serves.
- The old `gh-readonly` and `gh-prwrite` keyring entries are unused and can be
  deleted by hand.

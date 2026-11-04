# 0001: The gh shim stays in bash until a tipping point

Status: accepted, 2026-11-04

## Context

`dot-local/bin/gh` routes each `gh` call to a credential tier (see
`docs/gh-credential-scoping.md`). It was written for macOS: the read and
pr-write tokens came from `security`, so on Linux (CachyOS) every read fell
through to a 1Password approval, or to the raw binary's own login where `op` was
absent.

Linux support could be added in bash or by porting the shim to a compiled
language. Go was the candidate: `zalando/go-keyring` covers the macOS keychain
and the Linux Secret Service, real argv parsing would replace the hand-rolled
scanning, and startup stays in milliseconds. Python was ruled out because the
shim does a token lookup on nearly every call, and `keyring get` measured
170-330 ms. Plain `pass` was ruled out because gpg-agent's cache expiry brings
prompts back to the read tier.

Against a port: editing the shim through the stow symlink takes effect at once,
a binary needs a build step in `install.sh` and a prebuilt copy for the Linux
sandboxes, and nearly every rule in the shim records a past incident that a
rewrite could drop.

## Decision

Stay in bash. Every platform difference lives in `dot-local/bin/gh-keyring`,
which picks `security` on Darwin and `secret-tool` (libsecret) elsewhere. The
shim and `extras/gh-readonly-tokens.sh` call only `gh-keyring`, and neither
mentions an OS.

Port the shim to Go when **any one** of these happens:

1. **A third platform branch.** `gh-keyring` needs a third backend (Windows
   Credential Manager, WSL), or OS-specific code appears anywhere outside
   `gh-keyring`.
2. **Two more argv-parsing fixes.** Two bugs fixed after this ADR where the
   classifier or owner resolution misread argv: a flag value taken as an
   endpoint, a missed `--flag=value` spelling, a new verb shape. Label each
   such bead `gh-shim:argv`. `bd list --label gh-shim:argv --status closed`
   reaching 2 is the trigger. Adding a verb to an existing `case` list does not
   count.
3. **Size.** `dot-local/bin/gh` passes 750 lines. It was 555 at this decision.
4. **Structure bash does badly.** A feature that needs a token cached across
   invocations, JSON parsed from a `gh` or `op` response, concurrent work, or
   another helper-language workaround like the perl timeout watchdog.

Linux support on its own is not a trigger. This decision is the answer to it.

## Consequences

- Linux needs `libsecret` (`secret-tool`) and an unlocked keyring (KWallet 5.97+
  or gnome-keyring, unlocked at login through PAM) for silent reads. Without
  `secret-tool` the shim falls through tiers exactly as a Linux sandbox does.
- The bats suites pin `GH_KEYRING_BACKEND` so either backend is tested on
  either OS. `tests/gh-keyring.bats` owns the backend calls.
- When a trigger fires, port in two steps. First, a Go binary that passes the
  existing `tests/gh-shim.bats` unchanged, run as a black box, and keeps the
  three stderr lines `dot-claude/skills/1p-retry-band` reads. Second, swap
  `gh-keyring` for `go-keyring` and retire it. `install.sh` builds the binary;
  the sandbox image gets a prebuilt Linux one.

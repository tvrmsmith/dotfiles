# A `gh` wrapper that picks the credential from what the command does

If you have agents doing GitHub work, you've probably picked one of two bad
options: approve every action by hand until you're rubber-stamping dialogs
without reading them, or hand the agent one broad token and hope. I'd been on
the first for months and the prompts had stopped being decisions.

What made a third option possible is a split in GitHub's permission model I
hadn't noticed. Fine-grained PATs separate opening a PR from merging one:

- open a PR (`POST /repos/{o}/{r}/pulls`) needs **Pull requests: write**
- merge (`PUT .../pulls/{n}/merge`) needs **Contents: write**
- auto-merge needs **both**

A token with Pull requests write and Contents left at read opens PRs all day and
structurally cannot merge, cannot enable auto-merge, cannot push.

## The wrapper

`~/.local/bin/gh` shadows the real binary, classifies the command from argv
alone, and execs the real `gh` with the matching credential:

```
$ GH_SHIM_EXPLAIN=1 gh pr list               -> read some-org
$ GH_SHIM_EXPLAIN=1 gh pr create --fill      -> pr-write some-org
$ GH_SHIM_EXPLAIN=1 gh pr comment 1 -b x     -> pr-write some-org
$ GH_SHIM_EXPLAIN=1 gh pr merge 1            -> write
$ GH_SHIM_EXPLAIN=1 gh pr merge 1 --auto     -> write
$ GH_SHIM_EXPLAIN=1 gh pr review 1 --approve -> write
```

Read and pr-write pull a PAT from the OS keychain and run silently. `write`
escalates to a human approval (1Password here, swap in whatever you use).
`GH_SHIM_EXPLAIN` runs nothing, which is what makes the classifier testable with
no network and no prompt; there are 43 tests behind the shim and its
provisioning wizard.

## Four decisions that make it hold up

**Keyed by repo owner, not by account.** A fine-grained PAT has exactly one
resource owner, so a personal login, a work login, and each org each need their
own token. The wrapper resolves the owner per invocation from `-R owner/repo`,
the API path, or the git remote, and looks up that owner's token. Never
`gh auth switch`, which rewrites a shared `hosts.yml` and breaks the moment two
agents run in parallel.

**Two separate tokens, not one combined.** Tempting to give one token read plus
PR-write and drop a tier. Don't. Separate tokens mean a command the classifier
misreads as a read still 403s instead of succeeding, so every misclassification
is safe in both directions: a write treated as a read fails, a read treated as a
write costs one needless prompt. That property is what lets you be relaxed about
the classifier.

**Default deny.** Unknown subcommand, or a verb added in a future `gh` release,
takes the prompting path.

**Classification is the fiddly part.** `gh api` is the same command for reads and
writes, so it routes on method, and on whether a body flag is present, since `-f`
makes gh switch to POST on its own. GraphQL needed a special case: every
`gh api graphql` call is a POST carrying `-f query=`, so the body rule flagged
all of them, and a tool polling branch protection cost three approvals in one
second. It routes on the operation type in the query text instead, `query` versus
`mutation`.

Net effect: reads and PR creation are silent, merge and review and releases still
stop on a human, and the prompts that remain are rare enough that I read them.

## In this repo

- `dot-local/bin/gh` is the wrapper.
- `tests/gh-shim.bats` covers the classifier.
- `extras/gh-readonly-tokens.sh` provisions the tokens and the write tier's
  owner -> approval-source map; it's rerunnable.

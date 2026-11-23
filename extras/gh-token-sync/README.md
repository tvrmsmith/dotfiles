# gh-token-sync

Copies one classic GitHub token per account from 1Password into the OS keyring
every hour, where the gh shim reads it. Why: docs/adr/0002-agents-use-synced-classic-tokens.md.

## Set up once per Linux machine

| Step | Where | What |
|---|---|---|
| 1 | 1Password | A vault for agent credentials (a service account can't read Personal, Private or the default Shared vault). Put one classic token per GitHub account in it. |
| 2 | 1Password | A service account with read access to that vault only. Save its token. |
| 3 | Terminal | `mkdir -p ~/.config/gh-token-sync` then `systemd-creds encrypt --user --name=op-service-account - ~/.config/gh-token-sync/op-service-account.cred`, paste the service account token, press Ctrl-D. Needs systemd 256 or later. |
| 4 | Terminal | Write `~/.config/gh-token-sync/tokens`, one `owner op://vault/item/field` line per GitHub owner. A work user and a work org share one token, so they share one reference. |
| 5 | Terminal | `./install.sh` links the units and enables the timer. `systemctl --user start gh-token-sync` runs it now; `journalctl --user -u gh-token-sync` shows what it did. |

## A machine without the sync

Store the token by hand, once per owner, and again when it rotates:

    gh-keyring set gh-token <owner>   # paste the token, then Ctrl-D

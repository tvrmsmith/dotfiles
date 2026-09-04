# Beads Issue Tracker Active

Task tracking for this repo lives in `bd` (beads). Run `bd prime --export` for the
full command reference, `bd <cmd> --help` for one command.

## Core rules

- Use `bd` for ALL task tracking. Do NOT use TodoWrite, TaskCreate, or markdown
  TODO lists.
- Create the issue BEFORE writing code, and `bd update <id> --claim` when you start.
- Priority is `0`-`4` or `P0`-`P4`, where 0 is critical. Not high/medium/low.
- Do NOT run `bd edit`: it opens `$EDITOR` and blocks.

## Everyday commands

```bash
bd ready                 # work with no blockers
bd show <id>             # details, including what blocks it
bd create --title="..." --description="..." --type=task|bug|feature --priority=2
bd update <id> --claim   # take it
bd close <id> [<id>...] --reason="..."
bd dep add <id> <blocked-by-id>
```

## Before saying done

Close what you finished (`bd close`), and file beads for follow-up work rather
than leaving it in prose. Follow the repo's own instructions for whether to
commit, push, or sync; this file does not grant that authority.

Start: `bd ready`

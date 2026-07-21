# Review command failure gate

Command marked `user-invocable-only` in `skillOverrides` **cannot be invoked by the model** (subagent runs as model) — fails with:

```
Skill <name> is disabled for model invocation in skillOverrides settings
```

If invoking the review command fails (override-blocked, not installed, or typo), surface it: present the failure to the user with `AskUserQuestion`, echo the parsed command name, offer three choices:

1. **Pick another review skill** — ask for different review command, then retry the Review step with new command.
2. **Read the `.md` inline** — locate command's markdown file on disk (search
   `~/.claude/plugins/cache/**/commands/<name>.md`, `~/.claude/plugins/cache/**/skills/<name>/SKILL.md`,
   `~/.claude/plugins/marketplaces/**/commands/<name>.md`, `~/.claude/plugins/marketplaces/**/skills/<name>/SKILL.md`,
   and `~/.claude/skills/<name>/SKILL.md`), Read it, have subagent follow those instructions inline instead of invoking skill. Only offer when file actually located.
3. **Stop** — abort loop, report why.

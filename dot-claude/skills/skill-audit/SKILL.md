---
name: skill-audit
description: Audit and optimize loaded Claude Code skills — find overlaps, redundancies, tune visibility, and review budget settings.
---

# Skill Audit

Interactive audit of loaded Claude Code skills. Four phases: find overlaps, check native redundancies, tune visibility, review budget.

## Prerequisites

Resolve the real path of `~/.claude/settings.json` before any edits — it may be a symlink:

```bash
SETTINGS_PATH=$(readlink -f ~/.claude/settings.json 2>/dev/null || echo ~/.claude/settings.json)
```

## Step 0 — Inventory

Run the bundled scanner to collect all loaded skills, filter to enabled plugins, extract descriptions, and produce a sorted table:

```bash
python3 "$(dirname "$0")/scripts/scan_skills.py"
```

If the script path doesn't resolve (e.g. skill loaded via symlink), locate it:

```bash
SKILL_DIR=$(find ~/.claude/skills/skill-audit -maxdepth 1 -name "SKILL.md" -exec dirname {} \; 2>/dev/null | head -1)
python3 "$SKILL_DIR/scripts/scan_skills.py"
```

Use `--json` for structured output. The script reads `~/.claude/settings.json` and `~/.claude/plugins/installed_plugins.json` automatically.

The scanner outputs:
- Current budget settings and usage percentage
- Skill counts (active, hidden, disabled)
- Full table: skill name, plugin, description size, frontmatter status, current override

## Phase 1: Overlap Detection

### Step 1.1 — Detect overlaps

Using the inventory from Step 0, group skills that likely overlap by comparing:
- Name keywords (split on `-` and compare word sets)
- Description similarity (shared key terms)

Common overlap patterns to look for:
- Multiple "review" skills (code-review, pr-review, caveman-review)
- Multiple "test" skills (test-coverage, test-quality, test-planner, tdd)
- Multiple "plan" skills (writing-plans, executing-plans, plan-reviewer)
- Multiple "skill creation" skills (skill-creator, skill-builder, writing-skills)
- Skills that duplicate functionality of commands in the same plugin
- User-level skills that overlap with plugin skills

### Step 1.2 — Present overlaps interactively

For each overlapping group, use `AskUserQuestion` to present:
- The overlapping skills with their descriptions and source plugins
- Options:
  - **Keep all** — no changes
  - **Compare in detail** — drill deeper before deciding
  - **Mark specific ones as user-invocable-only** — hidden from auto-trigger, still invokable via `/name`
  - **Fully disable (off)** — completely removed from skill listing
  - **Consolidate** — keep one as the default, update it to reference the others, disable the rest

If the user picks **Compare in detail**: spawn an Explore subagent to read the full SKILL.md of each skill in the group and summarize differences. This keeps large skill files (300+ lines) out of main context. The subagent should report:
1. What each skill does (2-3 sentences)
2. What's unique to each
3. Where they overlap
4. Whether any are redundant

If the user picks **Consolidate**: update the kept skill to reference the disabled one(s) as a fallback (e.g. "For X operations, invoke `/disabled-skill-name`"). Then disable the others.

## Phase 2: Native Capability Redundancy Check

After resolving overlaps, check for skills that teach the agent things it already does natively. These skills add context overhead without meaningful value.

### Step 2.1 — Identify candidates

Scan remaining active skills for ones that match these patterns:
- **Framework/language detection** — the agent already checks package.json, requirements.txt, pom.xml, etc. when asked to work with a project
- **Code analysis/structure mapping** — the agent already reads and understands code structure, dependencies, and functions when it reads files
- **Test planning** — the agent naturally identifies test scenarios, edge cases, and strategies when asked to write tests
- **Basic file/project scanning** — the agent already knows how to find and read files

### Step 2.2 — Present candidates

For each candidate, use `AskUserQuestion` to present:
- Skill name, plugin, description size
- What the skill teaches
- Why the agent already handles this natively
- Options: **Keep as-is**, **Fully disable (off)**

Note: some skills in this category may be referenced by other skills/plugins as dependencies (e.g. unit-gen). Check if the referencing plugin has its own dedicated subagents that cover the same ground before disabling.

## Phase 3: Description Audit & Visibility Tuning

### Step 3.1 — Flag issues

From the inventory, flag:
- **CRITICAL**: Skills with no YAML frontmatter (loading entire file as description — potentially thousands of characters). Recommend submitting a PR to add frontmatter, or disabling as a workaround.
- **LARGE**: Description > current `skillListingMaxDescChars` (will be truncated)

### Step 3.2 — Interactive visibility tuning

Present remaining active skills in chunks of 3-4 via `AskUserQuestion`. For each skill show:
- Full qualified name (`plugin:skill-name`)
- Source plugin and marketplace
- Description size in characters
- First ~120 chars of description
- Current override status (if any)

Options for each:
- **Keep as-is** — stays in auto-trigger listing
- **Mark user-invocable-only** — removed from listing, still callable via `/name`
- **Fully disable (off)** — completely removed

Auto-suggest `user-invocable-only` for skills matching these patterns:
- Help/info skills (name contains `help`, `stats`, `status`, `info`)
- Compress/utility skills
- Skills the user explicitly invokes by name (setup wizards, one-time config)
- Skills with very niche triggers unlikely to fire organically

Skip skills already set to `user-invocable-only` or `off` in `skillOverrides`.

### Step 3.3 — Apply changes

After all selections, show a summary of changes and apply them to `skillOverrides` in the settings file. Use the resolved `$SETTINGS_PATH` from prerequisites.

## Phase 4: Budget Settings Review

### Step 4.1 — Current state

Report:
- Current `skillListingBudgetFraction` (default 0.05 if unset)
- Current `skillListingMaxDescChars` (default unlimited if unset)
- Count of active skills (after Phase 2-3 changes)
- Estimated total description chars loaded
- Budget usage percentage (chars used / chars available)
- Count of skills set to `user-invocable-only` and `off`

### Step 4.2 — Cap analysis

Calculate and present budget usage at multiple cap levels to help the user choose:

| Cap | Desc Total | With Overhead | Budget Usage |
|-----|-----------|---------------|-------------|
| 275 | ... | ... | ...% |
| 400 | ... | ... | ...% |
| 500 | ... | ... | ...% |
| 750 | ... | ... | ...% |
| 1024 | ... | ... | ...% |
| No cap | ... | ... | ...% |

Budget calculation:
- Context window: 200k tokens
- Budget capacity: `skillListingBudgetFraction × 200,000 × 4` chars (rough token-to-char ratio)
- Per-skill overhead: ~45 chars (name + formatting)
- Total = sum of capped descriptions + (active skill count × 45)

### Step 4.3 — Recommendations

Use `AskUserQuestion` to offer:
- Change `skillListingBudgetFraction` (suggest a value based on current usage)
- Change `skillListingMaxDescChars` (present the cap comparison table)
- Keep current settings

### Step 4.4 — Apply and verify

Apply any setting changes. Suggest the user run `/doctor` to verify the final state — it shows truncated/dropped skills and actual budget usage.

## Known Limitations

### Plugin skill overrides are ignored by Claude Code

Claude Code hardcodes `source==="plugin"` to return `"on"`, bypassing `skillOverrides` in `settings.json`. This means `user-invocable-only` and `off` overrides set during Phase 3 **only take effect for user-level skills** — plugin-scoped skills (e.g. `pr-review-toolkit:review-pr`) will remain active regardless of the override.

**Workaround (macOS only):** A binary patch script is included at `references/claude-code-patch.sh`. It replaces the hardcoded check so `skillOverrides` applies to all skill sources. Safe to re-run (detects if already patched), creates a `.bak` backup, and re-signs with original entitlements. Re-run after each Claude Code update.

**Preferred fix:** File a feature request with Anthropic to support `skillOverrides` for plugin skills natively.

---
name: skill-audit
description: Audit and optimize loaded Claude Code skills — scope plugins to relevant projects, find overlaps, check native redundancies, tune visibility, and review budget settings.
---

# Skill Audit

Interactive audit of loaded Claude Code skills. Five phases, ordered coarse to fine: scope plugins per project, find overlaps, check native redundancies, tune visibility, review budget.

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

## Phase 1: Per-Project Plugin Scoping

Plugins that only apply to specific tech stacks or organizational contexts load unnecessary skills in unrelated repos. This phase identifies them and scopes them to relevant projects. Run this first — no point auditing individual skills from plugins you're about to disable globally.

### Step 1.1 — Discover repos and tech stacks

Scan `~/dev` for repos and detect tech stacks:

```bash
# Find tech stack indicators
find ~/dev -maxdepth 3 \( \
  -name "*.csproj" -o -name "*.sln" -o \
  -name "Gemfile" -o -name "Rakefile" -o \
  -name "package.json" -o -name "go.mod" -o \
  -name "Cargo.toml" -o -name "pyproject.toml" -o \
  -name "Podfile" -o -name "*.xcodeproj" -o \
  -name "build.gradle" -o -name "*.tf" \
\) 2>/dev/null | sort

# List repos
find ~/dev -maxdepth 2 -type d | sort
```

Build a mapping: repo → tech stack(s).

### Step 1.2 — Inventory globally-enabled plugins

From `~/.claude/settings.json`, list all plugins with `true` in `enabledPlugins`. Plugins only load if explicitly set to `true` — omitting a plugin from `enabledPlugins` is equivalent to disabling it (see "How enabledPlugins works" below).

Also check `extraKnownMarketplaces` for registered marketplaces whose plugins aren't listed in `enabledPlugins`. These are NOT loading (despite being registered), but flag them for the user to decide whether to explicitly enable or leave disabled.

For each enabled plugin, classify:
- **General-purpose** — useful in any repo regardless of tech stack
- **Organization-specific** — only relevant in work repos (e.g. architecture docs, JIRA integration, OTEL telemetry)
- **Platform-specific** — only relevant for a subset of work repos (e.g. WellSky Home ecosystem plugins)
- **Tech-stack-specific** — only relevant for repos using a specific language/framework (e.g. .NET, Ruby, Terraform)

### Step 1.3 — Check existing per-project settings

```bash
find ~/dev -maxdepth 4 -path "*/.claude/settings*.json" -not -path "*/plugins/*" 2>/dev/null
```

For each, extract `enabledPlugins` and `skillOverrides` to understand what's already scoped.

### Step 1.4 — Define plugin tiers

Group non-general plugins into tiers based on scope. Example tier structure:

| Tier | Scope | Example |
|------|-------|---------|
| 1 | All work repos | architect, bug-fix, otel-telemetry, atlassian |
| 2 | Platform repos | ecosystem-specific plugins (e.g. wsh-*, hp) |
| 3 | Tech-stack repos | dotnet-*, ruby-lsp, csharp-lsp, terraform-* |

Present tier groupings via `AskUserQuestion`. Let user adjust which plugins go in which tier.

### Step 1.5 — Apply scoping

**Global settings.json** — remove `true` entries for non-general plugins (or set to `false` for explicit documentation):

```bash
SETTINGS_PATH=$(readlink -f ~/.claude/settings.json 2>/dev/null || echo ~/.claude/settings.json)
```

Edit `$SETTINGS_PATH` (not the symlink). Either delete the plugin key or set it to `false` — both prevent loading. Setting `false` is preferred for documentation clarity ("I intentionally disabled this" vs "I forgot to add it").

**Per-repo settings.local.json** — enable relevant tiers per repo with explicit `true` entries:
- Merge new `enabledPlugins` entries with any existing ones (preserve tech-specific plugins like csharp-lsp, terraform, ruby-lsp already in place)
- Create `.claude/` directory if it doesn't exist
- Use `settings.local.json` (gitignored) not `settings.json` (checked in) for per-user plugin preferences
- `enabledPlugins` must exist in `settings.json` (even as `{}`) for `settings.local.json` overrides to work — there is a known merge bug where local-only `enabledPlugins` is silently ignored

Claude Code settings are **per-repo only** — no directory-tree inheritance. Each repo needs its own `settings.local.json`. There is no way to set plugins for all repos under a directory.

### Step 1.6 — Verify

Report a summary table of changes:

| Repo | Tiers | Tech plugins |
|------|-------|-------------|
| repo-name | 1+2 | terraform, iac |
| repo-name | 1+2+3 | csharp-lsp, dotnet-* |

Suggest user start new Claude sessions in a personal repo and a work repo to confirm skill listings differ.

## Phase 2: Overlap Detection

### Step 2.1 — Detect overlaps

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

### Step 2.2 — Present overlaps interactively

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

## Phase 3: Native Capability Redundancy Check

Check for skills that teach the agent things it already does natively. These skills add context overhead without meaningful value.

### Step 3.1 — Identify candidates

Scan remaining active skills for ones that match these patterns:
- **Framework/language detection** — the agent already checks package.json, requirements.txt, pom.xml, etc. when asked to work with a project
- **Code analysis/structure mapping** — the agent already reads and understands code structure, dependencies, and functions when it reads files
- **Test planning** — the agent naturally identifies test scenarios, edge cases, and strategies when asked to write tests
- **Basic file/project scanning** — the agent already knows how to find and read files

### Step 3.2 — Present candidates

For each candidate, use `AskUserQuestion` to present:
- Skill name, plugin, description size
- What the skill teaches
- Why the agent already handles this natively
- Options: **Keep as-is**, **Fully disable (off)**

Note: some skills in this category may be referenced by other skills/plugins as dependencies (e.g. unit-gen). Check if the referencing plugin has its own dedicated subagents that cover the same ground before disabling.

## Phase 4: Description Audit & Visibility Tuning

### Step 4.1 — Flag issues

From the inventory, flag:
- **CRITICAL**: Skills with no YAML frontmatter (loading entire file as description — potentially thousands of characters). Recommend submitting a PR to add frontmatter, or disabling as a workaround.
- **LARGE**: Description > current `skillListingMaxDescChars` (will be truncated)

### Step 4.2 — Interactive visibility tuning

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

### Step 4.3 — Apply changes

After all selections, show a summary of changes and apply them to `skillOverrides` in the settings file. Use the resolved `$SETTINGS_PATH` from prerequisites.

## Phase 5: Budget Settings Review

### Step 5.1 — Current state

Report:
- Current `skillListingBudgetFraction` (default 0.05 if unset)
- Current `skillListingMaxDescChars` (default unlimited if unset)
- Count of active skills (after Phase 1-4 changes)
- Estimated total description chars loaded
- Budget usage percentage (chars used / chars available)
- Count of skills set to `user-invocable-only` and `off`

### Step 5.2 — Cap analysis

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

### Step 5.3 — Recommendations

Use `AskUserQuestion` to offer:
- Change `skillListingBudgetFraction` (suggest a value based on current usage)
- Change `skillListingMaxDescChars` (present the cap comparison table)
- Keep current settings

### Step 5.4 — Apply and verify

Apply any setting changes. Suggest the user run `/doctor` to verify the final state — it shows truncated/dropped skills and actual budget usage.

## How enabledPlugins works

Verified from Claude Code v2.1.150 binary source (function `checkEnabledPlugins`):

1. **Only explicitly `true` plugins load.** The function builds an enabled list by iterating `enabledPlugins` entries — only `true` values add to the list. Plugins not listed are not added.
2. **`false` = actively disabled.** If a plugin is `false`, it's removed from the enabled list (relevant when a broader scope enables it but a narrower scope disables it).
3. **Omitting a plugin = not loaded.** Functionally identical to `false`, but less explicit. Prefer `false` for documentation clarity.
4. **Settings merge order:** `policySettings → userSettings → projectSettings → localSettings → flagSettings`. Each layer can add (`true`) or remove (`false`) plugins. This is how project-level `settings.local.json` overrides work.
5. **Merge bug:** `enabledPlugins` in `settings.local.json` is silently ignored unless `enabledPlugins` key exists in `settings.json` (even as `{}`). See [#27247](https://github.com/anthropics/claude-code/issues/27247).
6. **Builtin plugins** (from `claude-plugins-official`) use a different code path with `defaultEnabled ?? true` fallback — these DO load by default even without being listed. External/marketplace plugins do not.

## Known Limitations

### Plugin skill overrides are ignored by Claude Code

Claude Code hardcodes `source==="plugin"` to return `"on"`, bypassing `skillOverrides` in `settings.json`. This means `user-invocable-only` and `off` overrides set during Phase 4 **only take effect for user-level skills** — plugin-scoped skills (e.g. `pr-review-toolkit:review-pr`) will remain active regardless of the override.

**Workaround (macOS only):** A binary patch script is included at `references/claude-code-patch.sh`. It replaces the hardcoded check so `skillOverrides` applies to all skill sources. Safe to re-run (detects if already patched), creates a `.bak` backup, and re-signs with original entitlements. Re-run after each Claude Code update.

**Preferred fix:** File a feature request with Anthropic to support `skillOverrides` for plugin skills natively.

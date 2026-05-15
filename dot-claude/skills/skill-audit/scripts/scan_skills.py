#!/usr/bin/env python3
"""Scan all loaded Claude Code skills and produce an inventory report.

Usage: python3 scan_skills.py [--json]

Reads ~/.claude/settings.json (resolves symlinks) and ~/.claude/plugins/installed_plugins.json
to find all enabled skills, extract descriptions, and report sizes/overrides.
"""

import json
import os
import re
import sys


def resolve_settings_path():
    p = os.path.expanduser("~/.claude/settings.json")
    return os.path.realpath(p) if os.path.islink(p) else p


def load_json(path):
    with open(os.path.expanduser(path)) as f:
        return json.load(f)


def extract_description(filepath):
    with open(filepath) as f:
        content = f.read()

    if not content.startswith("---"):
        return content, len(content), False

    fm_end = content.find("---", 3)
    if fm_end < 0:
        return content, len(content), False

    fm = content[3:fm_end]

    m = re.search(r"^description:\s*>\s*\n((?:\s+.*\n)*)", fm, re.MULTILINE)
    if m:
        desc = " ".join(line.strip() for line in m.group(1).strip().split("\n"))
        return desc, len(desc), True

    m = re.search(r'^description:\s*(.+?)$', fm, re.MULTILINE)
    if m:
        desc = m.group(1).strip().strip('"').strip("'")
        return desc, len(desc), True

    return "", 0, True


def scan_plugin_skills(cache_dir, enabled_plugins, active_versions, overrides):
    skills = []
    for root, _, files in os.walk(cache_dir):
        for fname in files:
            if fname.lower() != "skill.md":
                continue
            fpath = os.path.join(root, fname)
            rel = os.path.relpath(fpath, cache_dir)
            parts = rel.split(os.sep)
            if len(parts) < 5 or parts[3] != "skills":
                continue

            marketplace, plugin, version, _, skill_name = parts[:5]
            plugin_key = f"{plugin}@{marketplace}"

            if enabled_plugins.get(plugin_key) is False:
                continue
            active_ver = active_versions.get(plugin_key)
            if active_ver and version != active_ver:
                continue

            desc, desc_size, has_fm = extract_description(fpath)
            override_key = f"{plugin}:{skill_name}"
            override_val = overrides.get(override_key, "on")

            skills.append({
                "name": skill_name,
                "plugin": plugin,
                "marketplace": marketplace,
                "plugin_key": plugin_key,
                "desc": desc,
                "desc_size": desc_size,
                "has_frontmatter": has_fm,
                "override": override_val,
                "override_key": override_key,
                "path": fpath,
            })
    return skills


def scan_user_skills(skills_dir, overrides):
    skills = []
    if not os.path.exists(skills_dir):
        return skills

    for entry in os.listdir(skills_dir):
        skill_dir = os.path.join(skills_dir, entry)
        if os.path.islink(skill_dir):
            skill_dir = os.path.realpath(skill_dir)
        if not os.path.isdir(skill_dir):
            continue

        for fname in ("SKILL.md", "skill.md"):
            fpath = os.path.join(skill_dir, fname)
            if os.path.exists(fpath):
                desc, desc_size, has_fm = extract_description(fpath)
                override_val = overrides.get(entry, "on")
                skills.append({
                    "name": entry,
                    "plugin": "(user)",
                    "marketplace": "(user)",
                    "plugin_key": "(user)",
                    "desc": desc,
                    "desc_size": desc_size,
                    "has_frontmatter": has_fm,
                    "override": override_val,
                    "override_key": entry,
                    "path": fpath,
                })
                break
    return skills


def main():
    as_json = "--json" in sys.argv

    settings = load_json(resolve_settings_path())
    installed = load_json("~/.claude/plugins/installed_plugins.json")

    enabled = settings.get("enabledPlugins", {})
    overrides = settings.get("skillOverrides", {})
    max_desc = settings.get("skillListingMaxDescChars")
    budget = settings.get("skillListingBudgetFraction", 0.05)

    active_versions = {}
    for pk, installs in installed.get("plugins", {}).items():
        if installs:
            active_versions[pk] = installs[-1].get("version", "unknown")

    cache_dir = os.path.expanduser("~/.claude/plugins/cache")
    all_skills = scan_plugin_skills(cache_dir, enabled, active_versions, overrides)
    all_skills += scan_user_skills(os.path.expanduser("~/.claude/skills"), overrides)
    all_skills.sort(key=lambda s: -s["desc_size"])

    active = [s for s in all_skills if s["override"] not in ("user-invocable-only", "off")]
    hidden = [s for s in all_skills if s["override"] == "user-invocable-only"]
    disabled = [s for s in all_skills if s["override"] == "off"]

    total_raw = sum(s["desc_size"] for s in active)
    total_capped = sum(min(s["desc_size"], max_desc) if max_desc else s["desc_size"] for s in active)

    context_tokens = 200000
    budget_tokens = context_tokens * budget
    budget_chars = budget_tokens * 4
    overhead = len(active) * 45
    usage_chars = total_capped + overhead
    usage_pct = usage_chars / budget_chars * 100 if budget_chars else 0

    if as_json:
        print(json.dumps({
            "settings": {"budget": budget, "max_desc_chars": max_desc},
            "counts": {"total": len(all_skills), "active": len(active), "hidden": len(hidden), "disabled": len(disabled)},
            "budget": {"raw_chars": total_raw, "capped_chars": total_capped, "overhead": overhead, "total": usage_chars, "capacity": int(budget_chars), "usage_pct": round(usage_pct, 1)},
            "skills": [{k: v for k, v in s.items() if k != "path"} for s in all_skills],
        }, indent=2))
    else:
        print(f"Settings: budget={budget}, maxDescChars={max_desc}")
        print(f"Skills: {len(all_skills)} total | {len(active)} active | {len(hidden)} hidden | {len(disabled)} disabled")
        print(f"Budget: {usage_chars:,} / {int(budget_chars):,} chars ({usage_pct:.0f}% used)")
        print()
        print(f"{'#':>3} | {'Skill':<35} | {'Plugin':<25} | {'Size':>5} | {'FM':>3} | {'Override':<20}")
        print("-" * 105)
        for i, s in enumerate(all_skills, 1):
            fm = "Y" if s["has_frontmatter"] else "NO!"
            print(f"{i:3} | {s['name']:<35} | {s['plugin']:<25} | {s['desc_size']:>5} | {fm:>3} | {s['override']:<20}")


if __name__ == "__main__":
    main()

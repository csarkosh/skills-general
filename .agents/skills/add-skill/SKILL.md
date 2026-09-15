---
name: add-skill
description: Use when adding a new skill to skills-general, moving a skill in from another repository, or changing an existing skill in plugins/ — including renaming one, adding a script or asset to one, or deciding which plugin a skill belongs in.
---

# Adding or changing a shared skill

## 1. Pick the plugin

| The skill needs | Put it in |
| --- | --- |
| Only reading files, running shell commands, and editing | `plugins/general/skills/<name>/` (both agents) |
| A Claude Code-only tool: Artifact, Agent/subagents, `AskUserQuestion`, Skill, Workflow | `plugins/general-claude/skills/<name>/` |
| Anything about one specific repository (its deploy, its file layout, its conventions) | Not here. Keep it in that repository's `.agents/skills/` |

## 2. Write it

- `SKILL.md` frontmatter: `name` matches the folder (lowercase kebab-case), and
  `description` starts with "Use when" and says only when to use the skill.
- Supporting files go in `scripts/`, `assets/` or `references/`, and `SKILL.md` refers to
  them relative to the skill's folder ("`scripts/render.mjs` in this skill's directory").
  The tests check that every `scripts/…`, `assets/…` or `references/…` path named in
  backticks exists.
- A script imports nothing from `node_modules`. Vendor what it needs next to it, with the
  licence file beside it.
- For a skill moved in from another repository, strip anything specific to that repository
  (names, paths, themes it assumes).
- This repository is public, so nothing private to the source repository comes along.

## 3. Bump and register

1. Bump `version` in the plugin's `.claude-plugin/plugin.json` and, for `general`, in
   `.codex-plugin/plugin.json` to the same value. Without a bump, repositories that already
   installed the plugin may keep the old copy.
2. A new plugin needs an entry in `.claude-plugin/marketplace.json`, plus one in
   `.agents/plugins/marketplace.json` if Codex should get it.
3. Update the skills table in `AGENTS.md` and `README.md`.

## 4. Test

Run `npm test` (see the `test-plugins` skill). If the skill has a script, add an offline test
for it under `test/`, as `test/doc-preview.test.mjs` does. If the skill's description or
behaviour changed, check the repositories listed under Consumers in `AGENTS.md`.

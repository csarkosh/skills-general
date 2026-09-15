# skills-general — working context

Agent skills shared across Cyrus Sarkosh's repositories, published as one plugin marketplace
that both **Claude Code** and **Codex** install from. A repository that wants these skills
declares the marketplace in its own agent config instead of keeping a copy. The repo is
public, so everything in it is public too.

## Layout

| Path | What |
|---|---|
| `.claude-plugin/marketplace.json` | The Claude Code catalog: marketplace `csarkosh`, listing `general` and `general-claude`. |
| `.agents/plugins/marketplace.json` | The Codex catalog: the same marketplace name, listing only `general`. |
| `plugins/general/` | **Skills for both agents.** One `skills/` folder with a manifest per agent: `.claude-plugin/plugin.json` and `.codex-plugin/plugin.json`. |
| `plugins/general-claude/` | **Claude Code-only skills**, for skills that need Claude Code's own tools (the Artifact tool, subagents, `AskUserQuestion`). Claude manifest only. |
| `plugins/*/skills/<name>/` | One skill: `SKILL.md`, plus `scripts/`, `assets/` and `references/` as needed. |
| `test/` | `node --test` suites; `test/fixtures/sample-repo/` is the repository the live tests work in. |
| `.agents/skills/` | Skills for working **on this repo**: `add-skill` and `test-plugins`. `.claude/skills` is a symlink to it so Claude Code discovers them. |
| `AGENTS.md` | This file. `CLAUDE.md` points here. |
| `README.md` | Human-facing overview, including how another repository imports the plugins. |
| `LICENSE` | MIT. Vendored files keep their own licences beside them. |

## Skills in the plugins

| Plugin | Skill | What it does |
|---|---|---|
| `general` | `doc-preview` | Renders a markdown doc to a self-contained page in csarko.sh's theme and opens it in Chrome. |
| `general-claude` | `doc-artifact` | Publishes a markdown doc as a claude.ai Artifact in a Nord house style. |

## Workflows

- **Add or change a skill:** read `.agents/skills/add-skill/SKILL.md` first. It covers which
  plugin a skill belongs in, how to keep it agent-neutral, and the version bump.
- **Test:** `npm test` runs everything, including one real headless session per agent (it
  spends model tokens). `npm run test:offline` skips those. See
  `.agents/skills/test-plugins/SKILL.md` for logins and failures.

## Rules

- **A skill in `general` works in both agents.** It names no Claude Code-only tool or
  variable, and it refers to its own files by paths relative to its skill folder, never
  `${CLAUDE_PLUGIN_ROOT}` (Codex has no equivalent inside a skill). `test/structure.test.mjs`
  checks the known offenders.
- **Scripts carry their own dependencies.** An installed plugin has no `node_modules`, so a
  script vendors what it imports (as `doc-preview` vendors `marked`) and needs only Node.
- **Bump the version on every change to a plugin**, in every manifest that plugin has. Both
  agents cache installs by version, so a change without a bump may never reach a repository
  that already installed the plugin. The tests require the two manifests to match.
- **No Git LFS.** Plugin installs copy the files as they are, so a binary must be a real file
  in git. Keep binaries small (the two fonts are 80 KB together).
- **This repo is public.** Everything committed here, commit messages included, is visible to
  anyone. Keep skills free of anything private to the repositories they came from.

## Consumers

These repositories import the plugins. When a skill's name, plugin or behaviour changes, check
them:

- `csarkosh/game-dayhike`
- `csarkosh/csarko.sh`

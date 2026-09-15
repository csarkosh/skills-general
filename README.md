# skills-general

Agent skills I share across my repositories, packaged as one plugin marketplace that both
**Claude Code** and **Codex** can install from.

## What's here

| Plugin | For | Skills |
| --- | --- | --- |
| `general` | Claude Code and Codex | `doc-preview`: open a markdown doc as a styled page in Chrome<br>`search-console`: report a static site's Google indexing, sitemap and search performance |
| `general-claude` | Claude Code only | `doc-artifact`: publish a markdown doc as a claude.ai Artifact |

Each skill is a folder with a `SKILL.md` in the open [Agent Skills](https://agentskills.io)
format. Both agents read the same folder, and each plugin carries one small manifest per agent.

Scripts carry their own dependencies, so a skill needs only Node — except `search-console`,
which is Python: 3.9 or newer plus `google-auth`
(`python3 -m pip install --user google-auth`), and `gcloud` for its one-time setup script.

## Use it in a repository

**Claude Code:** add this to the repository's `.claude/settings.json`. Claude Code offers the
marketplace when someone trusts the folder; install the plugins with
`claude plugin install general@csarkosh` if it does not.

```json
{
  "extraKnownMarketplaces": {
    "csarkosh": { "source": { "source": "github", "repo": "csarkosh/skills-general" } }
  },
  "enabledPlugins": {
    "general@csarkosh": true,
    "general-claude@csarkosh": true
  }
}
```

**Codex:** add the marketplace once per machine, then install the plugin.

```bash
codex plugin marketplace add csarkosh/skills-general
codex plugin add general@csarkosh
```

Skills trigger on their own when a request matches their description. To call one by name, use
`/general:doc-preview` in Claude Code or `$doc-preview` in Codex.

## Test

```bash
npm test            # everything, including one real headless session in each agent
npm run test:offline  # no model calls: structure, the scripts, and installs from the marketplace
```

The tests install the plugins into throwaway config directories, so they never change your own
Claude Code or Codex setup. The live tests need both CLIs installed and logged in.

## Licences

MIT for this repository ([`LICENSE`](LICENSE)). Vendored files keep their own licences beside
them: Inter and JetBrains Mono under the SIL Open Font License 1.1, and `marked` under MIT.

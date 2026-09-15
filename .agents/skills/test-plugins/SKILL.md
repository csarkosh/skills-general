---
name: test-plugins
description: Use when running or debugging skills-general's tests, when a plugin test fails, or when checking that the plugins still install and work in Claude Code and Codex after a change.
---

# Testing the plugins

```bash
npm test               # all suites, including one live headless session per agent
npm run test:offline   # SKILLS_LIVE=0: no model calls
node --test test/codex.test.mjs   # one suite
```

## What each suite proves

| Suite | Proves | Model calls |
| --- | --- | --- |
| `test/structure.test.mjs` | The two marketplaces agree, every manifest pair matches, every `SKILL.md` is valid, `general` names no Claude Code-only tool | No |
| `test/doc-preview.test.mjs` | `render.mjs` renders a doc with nothing installed and no network | No |
| `test/claude.test.mjs` | `claude plugin validate --strict` passes; both plugins install from the marketplace, byte-identical; a headless `claude -p` session invokes `general:doc-preview` and runs the installed script | One session (sonnet) |
| `test/codex.test.mjs` | Codex lists only `general`; it installs byte-identical; a `codex exec` session runs the installed script | One session |

The live tests send a request that describes what the user wants without naming the skill, so
they also prove the skill's description triggers it.

## Isolation and logins

Every test installs into a throwaway `CLAUDE_CONFIG_DIR` or `CODEX_HOME` under the OS temp
directory and deletes it afterwards. Your own agent setup is never touched, with one exception
described below for Codex.

- **Claude Code** keeps its login in the macOS keychain, where a throwaway config directory can't
  find it. Set `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) or `ANTHROPIC_API_KEY` and
  the live session runs fully inside the throwaway directory. Without either, it uses your normal
  login with `--setting-sources project` (none of your own settings or plugins) and
  `--plugin-dir` pointed at the throwaway install.
- **Codex** logins live in `auth.json`. Set `CODEX_API_KEY` to avoid touching it. Otherwise the
  test copies `~/.codex/auth.json` into the throwaway `CODEX_HOME`. A ChatGPT login replaces its
  refresh token when it refreshes, which would log you out, so the test copies a refreshed
  `auth.json` back, unless something else changed the original meanwhile.

`SKILLS_CLAUDE_MODEL` and `SKILLS_CODEX_MODEL` override the models the live sessions use.

## When a test fails

| Symptom | Cause |
| --- | --- |
| `Not logged in · Please run /login` in the Claude result | A token variable is set but invalid, so the session ran in the throwaway directory without a login |
| `refresh token has expired` from Codex | Your Codex login expired. Run `codex login`, then rerun |
| `the session invoked general:doc-preview` fails, but the page exists | The agent did the work without the skill. The description no longer matches the request; fix the description, not the test |
| Installed copy differs from the source | A stale version: bump the plugin's version, or an install cached an older copy |
| `` `claude` is not installed `` / `` `codex` is not installed `` | Install the CLI, or use `npm run test:offline` |

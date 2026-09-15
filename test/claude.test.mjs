// Claude Code: the marketplace validates, both plugins install from it into a throwaway config
// directory, and a real headless session picks doc-preview from the installed copy and runs it.
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { before, describe, it } from 'node:test';
import {
  LIVE, MARKETPLACE, ROOT, cleanEnv, listFiles, parseJsonLines, previewPrompt, readJson, requireCli, run, runOk,
  sampleRepo, tempDir,
} from './helpers.mjs';

const PLUGINS = readJson(join(ROOT, '.claude-plugin/marketplace.json')).plugins.map((p) => p.name);

// Installs every plugin in the marketplace into a fresh CLAUDE_CONFIG_DIR and returns that directory.
function installAll(t) {
  const configDir = tempDir(t, 'claude-config');
  const env = cleanEnv({ CLAUDE_CONFIG_DIR: configDir });
  runOk('claude', ['plugin', 'marketplace', 'add', ROOT], { env });
  for (const plugin of PLUGINS) runOk('claude', ['plugin', 'install', `${plugin}@${MARKETPLACE}`], { env });
  const installed = JSON.parse(runOk('claude', ['plugin', 'list', '--json'], { env }).stdout);
  return { configDir, env, installed };
}

describe('Claude Code', () => {
  before(() => requireCli('claude'));

  it('validates the marketplace and every plugin with --strict', () => {
    runOk('claude', ['plugin', 'validate', '--strict', ROOT]);
    for (const plugin of PLUGINS) runOk('claude', ['plugin', 'validate', '--strict', join(ROOT, 'plugins', plugin)]);
  });

  it('installs every plugin from the marketplace, enabled and byte-identical to the source', (t) => {
    const { env, installed } = installAll(t);
    for (const plugin of PLUGINS) {
      const entry = installed.find((p) => p.id === `${plugin}@${MARKETPLACE}`);
      assert.ok(entry, `${plugin} is installed`);
      assert.equal(entry.enabled, true);
      const source = join(ROOT, 'plugins', plugin);
      for (const file of listFiles(join(source, 'skills'))) {
        const copy = join(entry.installPath, file.slice(source.length));
        assert.ok(readFileSync(copy).equals(readFileSync(file)), `${copy} matches the source`);
      }
    }
    const details = runOk('claude', ['plugin', 'details', `general@${MARKETPLACE}`], { env }).stdout;
    assert.match(details, /Skills \(\d+\)\s+.*\bdoc-preview\b/);
  });

  // With CLAUDE_CODE_OAUTH_TOKEN (from `claude setup-token`) or ANTHROPIC_API_KEY set, the session
  // runs entirely inside the throwaway config directory, plugin installed and enabled there. Without
  // one, a throwaway directory has no login, so the session uses the normal login but loads no user
  // or local settings (so none of your own plugins) and only the installed copy of the plugin.
  it('lets a headless session pick doc-preview from the installed plugin and render a doc', { skip: !LIVE && 'SKILLS_LIVE=0', timeout: 420_000 }, (t) => {
    const { configDir, installed } = installAll(t);
    const installPath = installed.find((p) => p.id === `general@${MARKETPLACE}`).installPath;
    const repo = sampleRepo(t);
    const out = tempDir(t, 'claude-out');
    const tokenAuth = Boolean(process.env.CLAUDE_CODE_OAUTH_TOKEN || process.env.ANTHROPIC_API_KEY);

    const args = [
      '-p', previewPrompt(out),
      '--output-format', 'stream-json', '--verbose', '--no-session-persistence',
      '--model', process.env.SKILLS_CLAUDE_MODEL ?? 'sonnet',
      '--allowedTools', 'Skill', 'Read', 'Glob', 'Bash(node:*)', 'Bash(ls:*)',
    ];
    if (!tokenAuth) args.push('--setting-sources', 'project', '--plugin-dir', installPath);
    const env = tokenAuth ? cleanEnv({ CLAUDE_CONFIG_DIR: configDir }) : cleanEnv();
    const { stdout, stderr, status } = run('claude', args, { cwd: repo, env, timeout: 400_000 });

    const events = parseJsonLines(stdout);
    const result = events.find((e) => e.type === 'result');
    assert.ok(result, `the session finished\n${stdout.slice(-2000)}\n${stderr}`);
    assert.equal(result.is_error, false, `the session succeeded: ${result.result}`);
    assert.equal(status, 0);

    const toolUses = events.filter((e) => e.type === 'assistant').flatMap((e) => e.message.content).filter((c) => c.type === 'tool_use');
    assert.ok(toolUses.some((c) => c.name === 'Skill' && c.input.skill === 'general:doc-preview'), 'the session invoked general:doc-preview');
    assert.ok(
      toolUses.some((c) => c.name === 'Bash' && c.input.command.includes(join(installPath, 'skills/doc-preview/scripts/render.mjs'))),
      'the session ran render.mjs from the installed plugin',
    );
    const page = join(out, '2026-01-02-sample-doc.html');
    assert.ok(existsSync(page), `${page} was written`);
    assert.match(readFileSync(page, 'utf8'), /<title>Sample research note<\/title>/);
  });
});

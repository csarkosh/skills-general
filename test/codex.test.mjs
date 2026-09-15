// Codex: the marketplace lists only the plugins meant for Codex, general installs from it into a
// throwaway CODEX_HOME, and a real `codex exec` session uses the installed doc-preview to render a doc.
import assert from 'node:assert/strict';
import { copyFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { before, describe, it } from 'node:test';
import {
  LIVE, MARKETPLACE, ROOT, cleanEnv, listFiles, parseJsonLines, previewPrompt, readJson, requireCli, run, runOk,
  sampleRepo, tempDir,
} from './helpers.mjs';

const PLUGINS = readJson(join(ROOT, '.agents/plugins/marketplace.json')).plugins.map((p) => p.name);
const CLAUDE_ONLY = readJson(join(ROOT, '.claude-plugin/marketplace.json')).plugins.map((p) => p.name).filter((name) => !PLUGINS.includes(name));

function installAll(t) {
  const home = tempDir(t, 'codex-home');
  const env = cleanEnv({ CODEX_HOME: home });
  runOk('codex', ['plugin', 'marketplace', 'add', ROOT], { env });
  for (const plugin of PLUGINS) runOk('codex', ['plugin', 'add', `${plugin}@${MARKETPLACE}`], { env });
  return { home, env };
}

const installRoot = (home, plugin) => {
  const { version } = readJson(join(ROOT, 'plugins', plugin, '.codex-plugin/plugin.json'));
  return join(home, 'plugins/cache', MARKETPLACE, plugin, version);
};

// Codex's ChatGPT login rotates its refresh token when it refreshes. A session run against a copy
// of auth.json can therefore invalidate the original, so copy a refreshed login back, but only if
// nothing else changed the original meanwhile. CODEX_API_KEY avoids all of this.
function borrowLogin(t, home) {
  if (process.env.CODEX_API_KEY) return;
  const real = join(process.env.CODEX_HOME ?? join(homedir(), '.codex'), 'auth.json');
  assert.ok(existsSync(real), `no Codex login at ${real}: run \`codex login\`, or set CODEX_API_KEY`);
  const original = readFileSync(real);
  const copy = join(home, 'auth.json');
  copyFileSync(real, copy);
  t.after(() => {
    if (!existsSync(copy)) return;
    const refreshed = readFileSync(copy);
    if (refreshed.equals(original)) return;
    if (readFileSync(real).equals(original)) writeFileSync(real, refreshed, { mode: 0o600 });
    else console.warn(`Codex login changed during the test; left ${real} as it is`);
  });
}

describe('Codex', () => {
  before(() => requireCli('codex'));

  it('lists only the plugins meant for Codex', (t) => {
    const home = tempDir(t, 'codex-home');
    const env = cleanEnv({ CODEX_HOME: home });
    runOk('codex', ['plugin', 'marketplace', 'add', ROOT], { env });
    const list = runOk('codex', ['plugin', 'list'], { env }).stdout;
    for (const plugin of PLUGINS) assert.match(list, new RegExp(`^${plugin}@${MARKETPLACE}\\s+not installed`, 'm'));
    for (const plugin of CLAUDE_ONLY) assert.doesNotMatch(list, new RegExp(`^${plugin}@`, 'm'), `${plugin} is Claude Code only`);
  });

  it('installs every plugin, enabled and byte-identical to the source', (t) => {
    const { home, env } = installAll(t);
    const list = runOk('codex', ['plugin', 'list'], { env }).stdout;
    for (const plugin of PLUGINS) {
      assert.match(list, new RegExp(`^${plugin}@${MARKETPLACE}\\s+installed, enabled`, 'm'));
      const source = join(ROOT, 'plugins', plugin);
      for (const file of listFiles(join(source, 'skills'))) {
        const copy = join(installRoot(home, plugin), file.slice(source.length));
        assert.ok(existsSync(copy) && readFileSync(copy).equals(readFileSync(file)), `${copy} matches the source`);
      }
    }
  });

  it('lets `codex exec` use the installed doc-preview to render a doc', { skip: !LIVE && 'SKILLS_LIVE=0', timeout: 420_000 }, (t) => {
    const { home, env } = installAll(t);
    borrowLogin(t, home);
    const repo = sampleRepo(t);
    const out = tempDir(t, 'codex-out');

    const args = ['exec', '--json', '--ephemeral', '--skip-git-repo-check', '--sandbox', 'workspace-write', '--add-dir', out, '-C', repo];
    if (process.env.SKILLS_CODEX_MODEL) args.push('--model', process.env.SKILLS_CODEX_MODEL);
    args.push(previewPrompt(out));
    const { stdout, stderr, status } = run('codex', args, { env, timeout: 400_000 });

    const events = parseJsonLines(stdout);
    const errors = events.filter((e) => e.type === 'error');
    assert.equal(errors.length, 0, `the session hit no errors: ${JSON.stringify(errors)}\n${stderr.slice(-2000)}`);
    assert.equal(status, 0, stderr.slice(-2000));
    const render = join(installRoot(home, 'general'), 'skills/doc-preview/scripts/render.mjs');
    assert.ok(stdout.includes(render), `the session ran ${render}`);
    const page = join(out, '2026-01-02-sample-doc.html');
    assert.ok(existsSync(page), `${page} was written`);
    assert.match(readFileSync(page, 'utf8'), /<title>Sample research note<\/title>/);
  });
});

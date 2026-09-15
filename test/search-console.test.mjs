// Offline: search-console's script reports its own problems instead of tracebacking, and its
// Python unit tests pass. Nothing here reaches the network or needs a credential.
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { ROOT, cleanEnv, run, runOk } from './helpers.mjs';

const SKILL = join(ROOT, 'plugins/general/skills/search-console');
const GSC = join(SKILL, 'scripts/gsc.py');
const skillText = readFileSync(join(SKILL, 'SKILL.md'), 'utf8');

// Enough to reach the credential check without a network call: an explicit property means the
// script never has to read the sitemap to guess one, and a missing local path is not fetched.
const OFFLINE_ARGS = ['sitemap', '--property', 'sc-domain:example.com', '--sitemap', '/nonexistent/sitemap.xml'];

describe('search-console', () => {
  it('declares itself as a skill named after its folder', () => {
    const match = /^---\n([\s\S]*?)\n---\n/.exec(skillText);
    assert.ok(match, 'SKILL.md starts with a frontmatter block');
    const meta = Object.fromEntries(match[1].split('\n').map((line) => {
      const colon = line.indexOf(':');
      return [line.slice(0, colon).trim(), line.slice(colon + 1).trim()];
    }));
    assert.equal(meta.name, 'search-console');
    assert.match(meta.description, /^Use when /);
    assert.ok(meta.description.length <= 1024);
  });

  it('names only scripts that exist', () => {
    const paths = [...skillText.matchAll(/`(scripts\/[^`\s…]+)`/g)].map((m) => m[1]);
    assert.ok(paths.includes('scripts/gsc.py'), 'SKILL.md points at scripts/gsc.py');
    assert.ok(paths.includes('scripts/setup.sh'), 'SKILL.md points at scripts/setup.sh');
    for (const path of paths) assert.ok(existsSync(join(SKILL, path)), `${path} exists`);
  });

  it('carries nothing from the repository it came from', () => {
    for (const file of ['scripts/gsc.py', 'scripts/setup.sh', 'scripts/tests/test_gsc.py']) {
      assert.doesNotMatch(readFileSync(join(SKILL, file), 'utf8'), /\.agents\/skills|AGENTS\.md/, `${file} assumes no host repository`);
    }
  });

  it('passes its Python unit tests', () => {
    const { stdout, stderr } = runOk('python3', ['-B', '-m', 'unittest', 'discover', '-s', 'scripts/tests'], { cwd: SKILL });
    assert.match(stdout + stderr, /\nOK\b/);
  });

  it('reports a missing service account key instead of tracebacking', () => {
    const env = cleanEnv({ GSC_SA_KEY: '/nonexistent/gsc-sa.json' });
    delete env.GSC_PROPERTY;
    delete env.GSC_SITEMAP;
    const { status, stdout, stderr } = run('python3', ['-B', GSC, ...OFFLINE_ARGS], { cwd: ROOT, env });
    assert.notEqual(status, 0, 'a missing credential is a failure');
    assert.doesNotMatch(stdout + stderr, /Traceback/);
    assert.match(stdout, /FAIL {2}no service account key at \/nonexistent\/gsc-sa\.json/);
    assert.match(stdout, /setup\.sh --project/, 'it points at the setup script');
    assert.match(stdout, /Users and permissions/, 'and at the grant that has no API');
  });

  it('asks for google-auth by name when it is not importable', (t) => {
    // A module named `google` that raises shadows the real package, so the import fails the way
    // it would on a machine without google-auth.
    const stub = join(ROOT, 'test/fixtures/no-google-auth');
    const key = join(stub, 'not-a-real-key.json');
    assert.ok(existsSync(key), 'the fixture carries a placeholder key file to get past the key check');
    const env = cleanEnv({ PYTHONPATH: stub, GSC_SA_KEY: key });
    delete env.GSC_PROPERTY;
    delete env.GSC_SITEMAP;
    const { status, stdout, stderr } = run('python3', ['-B', GSC, ...OFFLINE_ARGS], { cwd: ROOT, env });
    assert.notEqual(status, 0);
    assert.doesNotMatch(stdout + stderr, /Traceback/);
    assert.match(stdout, /google-auth is not installed: python3 -m pip install --user google-auth/);
    assert.match(skillText, /python3 -m pip install --user google-auth/, 'SKILL.md says so too');
  });
});

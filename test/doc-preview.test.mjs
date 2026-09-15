// Offline: doc-preview's script renders a doc on its own, with no install step and no network.
import assert from 'node:assert/strict';
import { cpSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { it } from 'node:test';
import { ROOT, SAMPLE_DOC, runOk, sampleRepo, tempDir } from './helpers.mjs';

const RENDER = join(ROOT, 'plugins/general/skills/doc-preview/scripts/render.mjs');

it('renders a self-contained page from a doc', (t) => {
  const repo = sampleRepo(t);
  const out = tempDir(t, 'out');
  const { stdout } = runOk('node', [RENDER, SAMPLE_DOC, '--out', out, '--no-open'], { cwd: repo });
  const page = join(out, '2026-01-02-sample-doc.html');
  assert.equal(stdout.trim(), page);
  assert.ok(existsSync(page));

  const html = readFileSync(page, 'utf8');
  assert.match(html, /<title>Sample research note<\/title>/);
  assert.match(html, /sample-repo<span>\/docs<\/span>/, 'the nav shows the repository and top folder');
  assert.match(html, /rendering · Jan 2, 2026/, 'the eyebrow shows the folder and the date from the file name');
  assert.match(html, /<p class="section-label">01<\/p><h2 id="a-numbered-section">/, 'a numbered H2 gets a mono label');
  assert.match(html, /<div class="scroll"><table>/, 'tables scroll in their own box');
  assert.match(html, /href="https:\/\/csarko\.sh" target="_blank" rel="noopener" class="external"/);
  assert.equal((html.match(/src: url\(data:font\/woff2;base64,/g) ?? []).length, 2, 'both fonts are embedded');
  for (const [file, type] of [['favicon.svg', 'image/svg+xml'], ['favicon-96x96.png', 'image/png']]) {
    const bytes = readFileSync(join(ROOT, 'plugins/general/skills/doc-preview/assets/favicon', file));
    assert.ok(html.includes(`<link rel="icon" href="data:${type};base64,${bytes.toString('base64')}"`), `the ${file} favicon is embedded`);
  }
  assert.doesNotMatch(html, /<(?:link|script)[^>]+(?:href|src)="https?:/, 'nothing loads from the network');
});

// Regression: installs live under ~/.claude, whose package.json can say "type": "commonjs". Node then
// reads any vendored .js file as CommonJS, so every module the script imports must be .mjs.
it('renders from an install under a package.json that declares CommonJS', (t) => {
  const parent = tempDir(t, 'commonjs');
  writeFileSync(join(parent, 'package.json'), '{ "type": "commonjs" }\n');
  const skill = join(parent, 'doc-preview');
  cpSync(join(ROOT, 'plugins/general/skills/doc-preview'), skill, { recursive: true });
  const repo = sampleRepo(t);
  const out = tempDir(t, 'out');
  runOk('node', [join(skill, 'scripts/render.mjs'), SAMPLE_DOC, '--out', out, '--no-open'], { cwd: repo });
  assert.ok(existsSync(join(out, '2026-01-02-sample-doc.html')));
});

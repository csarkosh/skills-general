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

// WCAG relative luminance and contrast ratio for #rrggbb colours.
function contrast(a, b) {
  const lum = (hex) => {
    const [r, g, bl] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
      .map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
  };
  const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

it('brands the header and footer with the favicon tile, readable in both themes', (t) => {
  const repo = sampleRepo(t);
  const out = tempDir(t, 'out');
  runOk('node', [RENDER, SAMPLE_DOC, '--out', out, '--no-open'], { cwd: repo });
  const html = readFileSync(join(out, '2026-01-02-sample-doc.html'), 'utf8');

  const nav = html.slice(html.indexOf('<nav'), html.indexOf('</nav>'));
  const footer = html.slice(html.indexOf('<footer'), html.indexOf('</footer>'));
  for (const [where, part] of [['header', nav], ['footer', footer]]) {
    assert.match(part, /<svg class="mark" width="\d+" height="\d+" aria-hidden="true"[^>]*><rect[^>]*class="mark-tile"\/><text[^>]*class="mark-glyph">cs<\/text><\/svg>/, `the ${where} carries the mark`);
  }

  // The swap: the tile is green and the glyph black, in the dark :root block and the light override.
  const token = (css, name) => new RegExp(`--${name}:\\s*(#[0-9a-f]{6})`, 'i').exec(css)?.[1];
  const dark = html.slice(html.indexOf(':root {'), html.indexOf('@media (prefers-color-scheme: light)'));
  const light = html.slice(html.indexOf('@media (prefers-color-scheme: light)'));
  for (const [theme, css] of [['dark', dark], ['light', light]]) {
    const [tile, glyph, page] = [token(css, 'mark-bg'), token(css, 'mark-fg'), token(css, 'bg')];
    assert.ok(tile && glyph && page, `the ${theme} theme defines --mark-bg, --mark-fg and --bg`);
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(tile.slice(i, i + 2), 16));
    assert.ok(g > r && g > b, `the ${theme} tile ${tile} is green`);
    assert.ok(contrast(glyph, '#000000') < 1.2, `the ${theme} glyph ${glyph} is black`);
    assert.ok(contrast(tile, glyph) >= 4.5, `the ${theme} glyph is readable on its tile (${contrast(tile, glyph).toFixed(2)}:1)`);
    assert.ok(contrast(tile, page) >= 3, `the ${theme} tile stands out from the page (${contrast(tile, page).toFixed(2)}:1)`);
  }
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

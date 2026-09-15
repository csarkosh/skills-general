#!/usr/bin/env node
// Renders a markdown doc to one self-contained HTML page in csarko.sh's theme and opens it in
// Chrome. The markdown stays the source of truth: write the page outside the repo, never commit it.
// Needs only Node 18+: marked is vendored next to this script and the fonts are embedded.
//
//   node <skill dir>/scripts/render.mjs <doc.md> [--out <dir>] [--no-open]
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Marked } from './vendor/marked.esm.mjs';

const args = process.argv.slice(2);
const flag = (name) => args.includes(name);
const option = (name) => (args.includes(name) ? args[args.indexOf(name) + 1] : undefined);
const source = args.find((arg, i) => !arg.startsWith('--') && args[i - 1] !== '--out');
if (!source) {
  console.error('usage: render.mjs <doc.md> [--out <dir>] [--no-open]');
  process.exit(2);
}

const path = resolve(source);
const markdown = readFileSync(path, 'utf8');
const outDir = resolve(option('--out') ?? join(tmpdir(), 'doc-preview'));
const outFile = join(outDir, `${basename(path, '.md')}.html`);

const escape = (text) => text.replace(/[&<>"']/g, (c) => `&${{ '&': 'amp', '<': 'lt', '>': 'gt', '"': 'quot', "'": '#39' }[c]};`);
const stripTags = (html) => html.replace(/<[^>]+>/g, '');

// Inter and JetBrains Mono (SIL OFL 1.1, see assets/fonts/OFL.txt) are embedded so the page works
// offline. If a font file is not real WOFF2 (say, a Git LFS pointer in a copy), fall back to system fonts.
function fontFace(family, weights, file) {
  const bytes = readFileSync(fileURLToPath(new URL(`../assets/fonts/${file}`, import.meta.url)));
  if (bytes.subarray(0, 4).toString('latin1') !== 'wOF2') {
    console.error(`assets/fonts/${file} is not a WOFF2 file; using system fonts.`);
    return '';
  }
  return `@font-face { font-family: "${family}"; font-style: normal; font-weight: ${weights}; font-display: swap; src: url(data:font/woff2;base64,${bytes.toString('base64')}) format("woff2"); }`;
}
const fonts = [
  fontFace('Inter', '400 700', 'inter-latin-var.woff2'),
  fontFace('JetBrains Mono', '400 500', 'jetbrains-mono-latin-var.woff2'),
].join('\n');

// csarko.sh's favicon, as the site serves it: the SVG, with the 96px PNG for browsers without SVG
// icons. Embedded as data URIs for the same offline reason as the fonts.
const dataUri = (file, type) => `data:${type};base64,${readFileSync(fileURLToPath(new URL(`../assets/favicon/${file}`, import.meta.url))).toString('base64')}`;
const favicons = [
  `<link rel="icon" href="${dataUri('favicon.svg', 'image/svg+xml')}" type="image/svg+xml">`,
  `<link rel="icon" href="${dataUri('favicon-96x96.png', 'image/png')}" type="image/png" sizes="96x96">`,
].join('\n');

// The same "cs" tile in the header and footer, built from favicon.svg so the shape never drifts from
// the site's icon, with its colours swapped: a green tile and black text. The fills become classes so
// the --mark-* tokens can give each theme its own green. Throws if the favicon's fills ever change.
const faviconSvg = readFileSync(fileURLToPath(new URL('../assets/favicon/favicon.svg', import.meta.url)), 'utf8');
const markSvg = faviconSvg.replace('fill="#0a0b0e"', 'class="mark-tile"').replace('fill="#7dd3c0"', 'class="mark-glyph"');
if (!markSvg.includes('class="mark-tile"') || !markSvg.includes('class="mark-glyph"')) {
  throw new Error('assets/favicon/favicon.svg no longer has the expected fills; update the mark in render.mjs');
}
const brandMark = (size) => markSvg.replace('<svg ', `<svg class="mark" width="${size}" height="${size}" aria-hidden="true" focusable="false" `);

// The first H1 becomes the page header; every H2 becomes a section and a stop on the contents rail.
// A numbered H2 ("1. Outlines") shows its number as a mono section label ("01") above the title.
const marked = new Marked({ gfm: true });
const tokens = marked.lexer(markdown);
const h1 = tokens.findIndex((t) => t.type === 'heading' && t.depth === 1);
const title = h1 >= 0 ? tokens.splice(h1, 1)[0].text : basename(path, '.md');

const rail = [];
const slugs = new Map();
marked.use({
  renderer: {
    heading({ tokens: inline, depth }) {
      let html = this.parser.parseInline(inline);
      let number = '';
      if (depth === 2) {
        const numbered = /^(\d+)\.\s+/.exec(html);
        if (numbered) {
          number = numbered[1].padStart(2, '0');
          html = html.slice(numbered[0].length);
        }
      }
      const base = stripTags(html).toLowerCase().replace(/&[a-z#0-9]+;/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'section';
      const count = slugs.get(base) ?? 0;
      slugs.set(base, count + 1);
      const id = count ? `${base}-${count}` : base;
      const heading = `<h${depth} id="${id}"><a class="anchor" href="#${id}">${html}</a></h${depth}>`;
      if (depth !== 2) return `${heading}\n`;
      rail.push({ id, number, text: stripTags(html) });
      return `<div class="section-head">${number ? `<p class="section-label">${number}</p>` : ''}${heading}</div>\n`;
    },
  },
});

const body = marked.parser(tokens)
  .replaceAll('<table>', '<div class="scroll"><table>').replaceAll('</table>', '</table></div>')
  .replaceAll('<pre>', '<div class="scroll"><pre>').replaceAll('</pre>', '</pre></div>')
  .replace(/<a href="(https?:[^"]+)"/g, '<a href="$1" target="_blank" rel="noopener" class="external"');

// Wordmark: the repo's name. Eyebrow: the doc's folder and, for YYYY-MM-DD-<topic>.md names, its date.
const repoRoot = (() => {
  try { return execFileSync('git', ['-C', dirname(path), 'rev-parse', '--show-toplevel'], { encoding: 'utf8' }).trim(); }
  catch { return dirname(path); }
})();
const repoPath = relative(repoRoot, path);
const repoName = basename(repoRoot);
const topFolder = repoPath.includes('/') ? repoPath.split('/')[0] : '';
const dated = /^(\d{4})-(\d{2})-(\d{2})-/.exec(basename(path));
const date = dated
  ? new Date(Date.UTC(+dated[1], +dated[2] - 1, +dated[3])).toLocaleDateString('en-US', { day: 'numeric', month: 'short', year: 'numeric', timeZone: 'UTC' })
  : '';
const kind = basename(dirname(path));
const words = stripTags(body).split(/\s+/).filter(Boolean).length;

const page = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="dark light">
<title>${escape(title)}</title>
${favicons}
<style>
${fonts}
@font-face { font-family: "Inter Fallback"; src: local("Arial"); size-adjust: 107.35%; ascent-override: 90.24%; descent-override: 22.47%; line-gap-override: 0%; }
@font-face { font-family: "JetBrains Mono Fallback"; src: local("Courier New"); size-adjust: 99.98%; ascent-override: 102.02%; descent-override: 30.00%; line-gap-override: 0%; }

/* csarko.sh's tokens. The theme follows the system setting; dark is the default. */
:root {
  color-scheme: dark;
  --bg: #0a0b0e;
  --surface: #111318;
  --surface-2: #161922;
  --border: rgba(255, 255, 255, 0.08);
  --border-strong: rgba(255, 255, 255, 0.14);
  --text: #e8eaf0;
  --muted: #a0a8b8;
  --faint: #7d8597;
  --accent: #7dd3c0;
  --on-accent: #06231d;
  --accent-tint: rgba(125, 211, 192, 0.08);
  --accent-glow: rgba(125, 211, 192, 0.10);
  --accent-underline: rgba(125, 211, 192, 0.35);
  --nav-bg: rgba(10, 11, 14, 0.72);
  /* The brand mark: the favicon with its colours swapped. Black on mint is 11.2:1. */
  --mark-bg: #7dd3c0;
  --mark-fg: #0a0b0e;
  --sans: "Inter", "Inter Fallback", ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  --mono: "JetBrains Mono", "JetBrains Mono Fallback", ui-monospace, "SF Mono", Menlo, Consolas, monospace;
  --radius: 14px;
}
@media (prefers-color-scheme: light) {
  :root {
    color-scheme: light;
    --bg: #f6f7f9;
    --surface: #ffffff;
    --surface-2: #eef0f4;
    --border: rgba(10, 11, 14, 0.09);
    --border-strong: rgba(10, 11, 14, 0.16);
    --text: #12151c;
    --muted: #4a5263;
    --faint: #5f677a;
    --accent: #0a735f;
    --on-accent: #ffffff;
    --accent-tint: rgba(125, 211, 192, 0.20);
    --accent-glow: rgba(125, 211, 192, 0.30);
    --accent-underline: rgba(10, 115, 95, 0.35);
    --nav-bg: rgba(246, 247, 249, 0.78);
    /* Mint vanishes on a light page and the deep accent is too dark for black text, so the mark
       takes the mint's hue at the lightness that clears both: black text 5.6:1, tile vs page 3.3:1. */
    --mark-bg: #349882;
    --mark-fg: #0a0b0e;
  }
}

*, *::before, *::after { box-sizing: border-box; }
html { scroll-behavior: smooth; scroll-padding-top: 84px; -webkit-text-size-adjust: 100%; }
body { margin: 0; background: var(--bg); color: var(--text); font: 16px/1.7 var(--sans); -webkit-font-smoothing: antialiased; }
body::before {
  content: ""; position: fixed; inset: -20vh -10vw auto; height: 70vh; pointer-events: none; z-index: -1;
  background: radial-gradient(ellipse at 30% 0%, var(--accent-glow), transparent 60%);
}
::selection { background: var(--accent); color: var(--on-accent); }
:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; border-radius: 6px; }

.wrap { max-width: 1120px; margin: 0 auto; padding-inline: 24px; }

.nav {
  position: sticky; top: 0; z-index: 10; background: var(--nav-bg); border-bottom: 1px solid var(--border);
  backdrop-filter: saturate(140%) blur(12px); -webkit-backdrop-filter: saturate(140%) blur(12px);
}
.nav .wrap { display: flex; align-items: center; justify-content: space-between; gap: 16px; height: 60px; }
.wordmark { font: 500 15px var(--mono); letter-spacing: -0.01em; color: var(--text); text-decoration: none; display: inline-flex; align-items: center; gap: 10px; min-width: 0; }
.mark { display: block; flex: none; }
.mark .mark-tile { fill: var(--mark-bg); }
.mark .mark-glyph { fill: var(--mark-fg); }
.wordmark .name span { color: var(--accent); }
.nav .path { font: 12.5px var(--mono); color: var(--faint); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

.shell { display: grid; grid-template-columns: minmax(0, 1fr); gap: 64px; padding-block: 72px 96px; }
@media (min-width: 1060px) { .shell { grid-template-columns: 230px minmax(0, 72ch); justify-content: center; } }

.rail { display: none; }
@media (min-width: 1060px) {
  .rail { display: block; position: sticky; top: 108px; align-self: start; max-height: calc(100vh - 140px); overflow-y: auto; padding-left: 6px; }
}
.rail .section-label { margin-bottom: 16px; }
.rail ol { list-style: none; margin: 0; padding: 0 0 0 20px; border-left: 1px solid var(--border-strong); display: grid; gap: 4px; }
.rail li { position: relative; }
.rail a { display: flex; gap: 10px; padding: 4px 0; color: var(--muted); font-size: 13.5px; line-height: 1.45; text-decoration: none; transition: color .15s ease; }
.rail a:hover { color: var(--text); }
.rail a .num { font: 12px/1.6 var(--mono); color: var(--faint); flex: none; }
.rail a::before {
  content: ""; position: absolute; left: -25px; top: 11px; width: 9px; height: 9px; border-radius: 50%;
  background: var(--bg); border: 2px solid var(--border-strong); transition: border-color .15s ease;
}
.rail a.active { color: var(--text); }
.rail a.active::before { border-color: var(--accent); }

.hero { padding-bottom: 36px; }
.eyebrow {
  font: 12px var(--mono); letter-spacing: 0.12em; text-transform: uppercase; color: var(--accent);
  margin: 0 0 20px; display: inline-flex; align-items: center; gap: 10px;
}
.eyebrow::before { content: ""; width: 8px; height: 8px; border-radius: 50%; background: var(--accent); box-shadow: 0 0 12px var(--accent); }
.hero h1 { font-size: clamp(2.2rem, 5.5vw, 3.4rem); line-height: 1.05; letter-spacing: -0.035em; font-weight: 700; margin: 0 0 24px; text-wrap: balance; }
.tags { display: flex; flex-wrap: wrap; gap: 6px; margin: 0; padding: 0; list-style: none; }
.tags li {
  font: 12px/1.5 var(--mono); color: var(--muted); background: var(--surface-2); border: 1px solid var(--border);
  padding: 3px 9px; border-radius: 999px; overflow-wrap: anywhere;
}

.section-label { font: 12px var(--mono); letter-spacing: 0.12em; text-transform: uppercase; color: var(--faint); margin: 0 0 8px; }
.section-head { border-top: 1px solid var(--border); padding-top: 48px; margin-top: 56px; }
h2, h3, h4 { color: var(--text); text-wrap: balance; }
h2 { font-size: 1.75rem; line-height: 1.2; letter-spacing: -0.025em; font-weight: 600; margin: 0 0 24px; }
h3 { font-size: 1.2rem; letter-spacing: -0.015em; font-weight: 600; margin: 36px 0 12px; }
.anchor { color: inherit; text-decoration: none; }

p, li { color: var(--muted); text-wrap: pretty; overflow-wrap: anywhere; }
main > p:first-of-type { margin-top: 0; }
strong { color: var(--text); font-weight: 600; }
ul, ol { padding-left: 1.25em; }
li { margin: 12px 0; }
.rail li, .tags li { margin: 0; }
li::marker { color: var(--accent); }
a { color: var(--accent); text-decoration: underline; text-decoration-color: var(--accent-underline); text-underline-offset: 3px; transition: text-decoration-color .15s ease; }
a:hover { text-decoration-color: var(--accent); }
a.external::after { content: "↗"; font-size: .72em; margin-left: 2px; vertical-align: .3em; text-decoration: none; display: inline-block; }

code { font: .86em var(--mono); color: var(--text); background: var(--surface-2); border: 1px solid var(--border); border-radius: 6px; padding: .12em .4em; }
.scroll { overflow-x: auto; margin: 24px 0; background: var(--surface); border: 1px solid var(--border); border-radius: var(--radius); }
pre { margin: 0; padding: 18px 20px; font: 13.5px/1.6 var(--mono); }
pre code { background: none; border: 0; padding: 0; }
table { border-collapse: collapse; width: 100%; font-size: 14.5px; font-variant-numeric: tabular-nums; }
th { font: 500 11.5px var(--mono); letter-spacing: 0.1em; text-transform: uppercase; color: var(--faint); background: var(--surface-2); }
th, td { text-align: left; padding: 12px 16px; border-bottom: 1px solid var(--border); vertical-align: top; color: var(--muted); }
tr:last-child td { border-bottom: 0; }
blockquote {
  margin: 28px 0; padding: 18px 22px; border: 1px solid var(--border); border-radius: var(--radius);
  background: linear-gradient(135deg, var(--accent-tint), transparent 55%), var(--surface);
}
blockquote p { margin: 0; }
hr { border: 0; border-top: 1px solid var(--border); margin: 48px 0; }

footer { border-top: 1px solid var(--border); padding-block: 28px 40px; color: var(--faint); font-size: 13px; }
footer .wrap { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 8px; }
footer .mono { font-family: var(--mono); }
footer .brand { display: inline-flex; align-items: center; gap: 8px; }

@media (max-width: 640px) {
  .nav .path { display: none; }
  .shell { padding-block: 48px 72px; }
  .section-head { padding-top: 40px; margin-top: 44px; }
}
@media (prefers-reduced-motion: reduce) {
  html { scroll-behavior: auto; }
  .rail a, .rail a::before, a { transition: none; }
}
@media print {
  body::before, .nav, .rail { display: none; }
  .shell { display: block; padding: 0; }
}
</style>
</head>
<body>
<nav class="nav" aria-label="Document">
  <div class="wrap">
    <a class="wordmark" href="#top">${brandMark(26)}<span class="name">${escape(repoName)}${topFolder ? `<span>/${escape(topFolder)}</span>` : ''}</span></a>
    <span class="path">${escape(repoPath)}</span>
  </div>
</nav>
<div class="wrap shell">
  <aside class="rail" aria-label="Contents">
    <p class="section-label">Contents</p>
    <ol>${rail.map((s) => `<li><a href="#${s.id}">${s.number ? `<span class="num">${s.number}</span>` : ''}<span>${escape(s.text)}</span></a></li>`).join('')}</ol>
  </aside>
  <main id="top">
    <header class="hero">
      <p class="eyebrow">${escape(kind)}${date ? ` · ${date}` : ''}</p>
      <h1>${escape(title)}</h1>
      <ul class="tags"><li>${escape(repoPath)}</li><li>${Math.max(1, Math.round(words / 230))} min read</li></ul>
    </header>
    ${body}
  </main>
</div>
<footer>
  <div class="wrap"><span class="brand">${brandMark(20)}${escape(repoName)}</span><span class="mono">${escape(repoPath)}</span></div>
</footer>
<script>
  const links = [...document.querySelectorAll('.rail a')];
  const byId = new Map(links.map((a) => [decodeURIComponent(a.hash.slice(1)), a]));
  // Highlight the section whose heading last crossed the top third of the viewport.
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      links.forEach((a) => a.classList.remove('active'));
      byId.get(entry.target.id)?.classList.add('active');
    }
  }, { rootMargin: '-60px 0px -70% 0px' });
  document.querySelectorAll('main h2[id]').forEach((h) => observer.observe(h));
</script>
</body>
</html>
`;

mkdirSync(outDir, { recursive: true });
writeFileSync(outFile, page);
console.log(outFile);

if (!flag('--no-open')) {
  const opener = {
    darwin: ['open', ['-a', 'Google Chrome', outFile]],
    win32: ['cmd', ['/c', 'start', '', 'chrome', outFile]],
  }[process.platform] ?? ['xdg-open', [outFile]];
  try { execFileSync(...opener, { stdio: 'ignore' }); }
  catch { console.error(`Could not open Chrome; open ${outFile} by hand.`); }
}

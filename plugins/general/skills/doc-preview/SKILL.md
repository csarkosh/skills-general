---
name: doc-preview
description: Use when the user asks to open, preview, or read a markdown document from a repository (research note, spec, plan, design doc, anything under docs/) as a styled HTML page in Chrome or a local browser, rather than as a published or shared page.
---

# Markdown docs in Chrome

Renders one markdown doc to a self-contained HTML page in the theme of
[csarko.sh](https://csarko.sh), then opens it in Google Chrome. It's local and private, and
nothing is published.

The theme is csarko.sh's own. It follows the system light/dark setting, with dark as the
default: near-black ground, teal accent (`#7dd3c0`, or `#0a735f` in light), Inter for text,
JetBrains Mono for eyebrows, labels and paths, a soft accent glow at the top, and a blurred
sticky nav. The colour tokens at the top of the `<style>` block in `scripts/render.mjs` are
copied from csarko.sh. If csarko.sh's palette changes, copy the new tokens across.

## Run it

The script is `scripts/render.mjs` in this skill's directory, the folder that holds this
`SKILL.md`. It needs Node 18 or newer and nothing else: `marked` is vendored beside it and the
fonts are in `assets/fonts/`. Run it from the repository that holds the doc, and write the page
outside that repository, such as your session's scratch or temp directory:

```bash
node <this skill's directory>/scripts/render.mjs docs/rendering/2026-09-14-stylized-shader-looks.md --out <scratch dir>/doc-preview
```

It prints the HTML path and opens it with `open -a "Google Chrome"` on macOS (`start chrome`
on Windows, `xdg-open` elsewhere). `--no-open` writes the page without opening it. Without
`--out`, the page goes to the OS temp directory under `doc-preview/`.

The page is built from the doc itself:

- the nav shows the repository's name and the doc's top-level folder, such as `game-dayhike/docs`
- the first `# H1` becomes the page header
- every `## H2` starts a section and becomes a stop on the sticky contents rail (at 1060px and wider)
- a numbered `## 1. Title` shows its number as a mono label (`01`) above the title
- the eyebrow shows the doc's folder, plus its date when the name follows `YYYY-MM-DD-<topic>.md`
- tables and code blocks scroll sideways inside their own boxes
- external links open in a new tab and carry a ↗ mark
- the tab shows csarko.sh's favicon (`assets/favicon/`, copied from the live site with the
  PNG's EXIF chunk stripped). If the site's favicon changes, copy the new files across

Everything is inlined, fonts and favicon included, so the page also works offline. The fonts are SIL OFL
1.1 (`assets/fonts/OFL.txt`) and `marked` is MIT (`scripts/vendor/marked-LICENSE.md`).

## Common mistakes

| Mistake | Fix |
| --- | --- |
| Writing the HTML into the repository | The markdown is the source of truth and the page is build output. Write to a scratch or temp directory |
| Hand-writing a one-off HTML page | Run the script so every doc renders the same way. To change the look, edit `scripts/render.mjs` |
| `assets/fonts/… is not a WOFF2 file` | The font files were replaced by something else, such as Git LFS pointers. The page still renders, in system fonts |
| Screenshotting at 400px with headless Chrome on macOS | Headless Chrome won't lay out narrower than 500px, so the image looks clipped. Measure `document.documentElement.scrollWidth` with `--dump-dom` instead |
| Headless Chrome never exits after `--screenshot` | Wrap it: `perl -e 'alarm 40; exec @ARGV' "<chrome>" --headless=new …` |

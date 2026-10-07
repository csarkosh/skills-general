// Offline: menubar-stats' scripts parse and typecheck, and setup.sh keeps the layout SKILL.md
// describes: the order, the optional tighter spacing, and MacStats installed with its own installer
// from csarkosh/app-macstats. Nothing is installed, no setting is written and no app is started or quit.
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { ROOT, runOk } from './helpers.mjs';

const SKILL = join(ROOT, 'plugins/general/skills/menubar-stats');
const SCRIPTS = join(SKILL, 'scripts');
const FILES = ['SKILL.md', 'scripts/setup.sh', 'scripts/menubar-order.swift'];
const skillText = readFileSync(join(SKILL, 'SKILL.md'), 'utf8');
const setup = readFileSync(join(SCRIPTS, 'setup.sh'), 'utf8');

describe('menubar-stats', () => {
  it('names only scripts that exist', () => {
    const paths = [...skillText.matchAll(/`(scripts\/[^`\s…*]+)`/g)].map((m) => m[1]);
    assert.ok(paths.includes('scripts/setup.sh'), 'SKILL.md points at scripts/setup.sh');
    for (const path of paths) assert.ok(existsSync(join(SKILL, path)), `${path} exists`);
  });

  it('carries no machine paths', () => {
    for (const file of FILES) {
      assert.doesNotMatch(readFileSync(join(SKILL, file), 'utf8'), /\/Users\/|\.agents\/skills|AGENTS\.md/, `${file} assumes no host machine or repository`);
    }
  });

  it('installs MacStats with its own installer, and removes it the same way', () => {
    const installer = 'https://raw.githubusercontent.com/csarkosh/app-macstats/main/install.sh';
    assert.ok(setup.includes(`INSTALLER="${installer}"`), 'setup.sh names the installer');
    assert.match(setup, /curl -fsSL "\$INSTALLER" \| sh -s -- "\$@"/, 'runs it with curl | sh, passing options through');
    assert.match(setup, /install_macstats --uninstall/, '--uninstall hands off to the installer');
    assert.ok(!setup.includes('swiftc -O'), 'builds nothing itself');
    assert.ok(skillText.includes('github.com/csarkosh/app-macstats'), 'SKILL.md points at the app repository');
  });

  it('has a setup.sh that bash can parse', () => {
    runOk('bash', ['-n', join(SCRIPTS, 'setup.sh')]);
  });

  it('places CPU, GPU, RAM, Temp and Disk left-most in that order, then Zoom', () => {
    const position = (name) => {
      const match = new RegExp(`"\\$POS ${name}" -float (\\d+)`).exec(setup);
      assert.ok(match, `setup.sh saves a position for ${name}`);
      return Number(match[1]);
    };
    const order = ['MacStatsCPU', 'MacStatsGPU', 'MacStatsRAM', 'MacStatsTemp', 'MacStatsDisk', 'Item-0'].map(position);
    for (let i = 1; i < order.length; i++) assert.ok(order[i - 1] > order[i], 'a larger number sits further left');
  });

  it('offers tighter icon spacing as an option, never by default, and says how to undo it', () => {
    assert.match(setup, /if \[ "\$TIGHT" = 1 \]; then\n\s+defaults -currentHost write -globalDomain NSStatusItemSpacing -int 6/,
      'writes the spacing only with --tight-spacing');
    assert.match(setup, /defaults -currentHost delete -globalDomain NSStatusItemSpacing/, 'says how to undo it');
  });

  it('typechecks the menu bar order script', () => {
    runOk('xcrun', ['swiftc', '-typecheck', join(SCRIPTS, 'menubar-order.swift')]);
  });
});

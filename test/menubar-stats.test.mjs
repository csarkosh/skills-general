// Offline: menubar-stats' scripts compile, DiskMenu draws itself to a PNG and lists the disk's spaces
// and folders, and setup.sh orders the items as SKILL.md says. Nothing is installed, no setting is
// written and no app is started or quit.
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { ROOT, runOk, tempDir } from './helpers.mjs';

const SKILL = join(ROOT, 'plugins/general/skills/menubar-stats');
const SCRIPTS = join(SKILL, 'scripts');
const FILES = ['SKILL.md', 'scripts/setup.sh', 'scripts/diskmenu.swift', 'scripts/menubar-order.swift'];
const skillText = readFileSync(join(SKILL, 'SKILL.md'), 'utf8');
const setup = readFileSync(join(SCRIPTS, 'setup.sh'), 'utf8');

describe('menubar-stats', () => {
  it('names only scripts that exist', () => {
    const paths = [...skillText.matchAll(/`(scripts\/[^`\s…]+)`/g)].map((m) => m[1]);
    assert.ok(paths.includes('scripts/setup.sh'), 'SKILL.md points at scripts/setup.sh');
    for (const path of paths) assert.ok(existsSync(join(SKILL, path)), `${path} exists`);
  });

  it('carries no machine paths', () => {
    for (const file of FILES) {
      assert.doesNotMatch(readFileSync(join(SKILL, file), 'utf8'), /\/Users\/|\.agents\/skills|AGENTS\.md/, `${file} assumes no host machine or repository`);
    }
  });

  it('has a setup.sh that bash can parse', () => {
    runOk('bash', ['-n', join(SCRIPTS, 'setup.sh')]);
  });

  it('places CPU, GPU, RAM, the temperatures and Disk left-most in that order, then Zoom', () => {
    const position = (name) => {
      const match = new RegExp(`"\\$POS ${name}" -float (\\d+)`).exec(setup);
      assert.ok(match, `setup.sh saves a position for ${name}`);
      return Number(match[1]);
    };
    const order = ['CPU_mini', 'GPU_mini', 'RAM_mini', 'Sensors_sensors', 'DiskMenu', 'Item-0'].map(position);
    for (let i = 1; i < order.length; i++) assert.ok(order[i - 1] > order[i], 'a larger number sits further left');
  });

  it('typechecks the menu bar order script', () => {
    runOk('xcrun', ['swiftc', '-typecheck', join(SCRIPTS, 'menubar-order.swift')]);
  });

  describe('DiskMenu', () => {
    let binary;
    before(() => {
      binary = join(mkdtempSync(join(tmpdir(), 'skills-general-diskmenu-')), 'DiskMenu');
      runOk('xcrun', ['swiftc', '-O', join(SCRIPTS, 'diskmenu.swift'), '-o', binary], { timeout: 300_000 });
    });
    after(() => rmSync(dirname(binary), { recursive: true, force: true }));

    it('renders its item as used/total GB', (t) => {
      const png = join(tempDir(t, 'diskmenu-png'), 'item.png');
      const { stdout } = runOk(binary, ['--render', png]);
      assert.match(stdout, /^\d+\.\d\/\d+\.\d GB\n$/);
      assert.deepEqual([...readFileSync(png).subarray(0, 4)], [0x89, 0x50, 0x4e, 0x47], 'writes a PNG');
    });

    it('lists the five spaces in the window\'s order', () => {
      const titles = runOk(binary, ['--spaces']).stdout.trim().split('\n').map((line) => line.split('\t')[0]);
      assert.deepEqual(titles, ['macOS system', 'update/boot', 'recovery', 'swap', 'my apps / files']);
    });

    it('lists folders three deep, biggest first, with an app as one row', (t) => {
      const root = tempDir(t, 'diskmenu-tree');
      const file = (path, megabytes) => {
        mkdirSync(join(root, dirname(path)), { recursive: true });
        writeFileSync(join(root, path), randomBytes(megabytes * 1024 * 1024));
      };
      file('small/a/b/c/four-deep.bin', 3);
      file('big/one.bin', 5);
      file('Thing.app/Contents/MacOS/thing', 2);
      file('tiny/under-the-cut-off.bin', 0.25);
      const { stdout } = runOk(binary, ['--report', root, '--min-mb', '1']);
      const lines = stdout.trimEnd().split('\n').map((line) => line.split('\t')[0]);
      assert.deepEqual(lines, ['big', 'small', '  a', '    b', 'Thing.app']);
    });
  });
});

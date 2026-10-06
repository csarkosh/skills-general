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

    it('gives every Spaces row under Used a colour, in the panel\'s order', () => {
      const rows = runOk(binary, ['--legend']).stdout.trim().split('\n').map((line) => line.split('\t'));
      assert.deepEqual(rows.map(([title]) => title),
        ['macOS system', 'update/boot', 'recovery', 'swap', 'my apps / files', 'other', 'Purgeable', 'Free']);
      for (const [title, color] of rows) assert.ok(color, `${title} has a colour`);
    });

    it('lists the five spaces in the panel\'s order', () => {
      const titles = runOk(binary, ['--spaces']).stdout.trim().split('\n').map((line) => line.split('\t')[0]);
      assert.deepEqual(titles, ['macOS system', 'update/boot', 'recovery', 'swap', 'my apps / files']);
    });

    const tree = (t, files) => {
      const root = tempDir(t, 'diskmenu-tree');
      for (const [path, megabytes] of Object.entries(files)) {
        mkdirSync(join(root, dirname(path)), { recursive: true });
        writeFileSync(join(root, path), randomBytes(megabytes * 1024 * 1024));
      }
      const { stdout } = runOk(binary, ['--report', root, '--min-mb', '1']);
      return stdout.trimEnd().split('\n').map((line) => line.replace('\t', ' | '));
    };

    it('lists folders three deep, biggest first, with an app as one row', (t) => {
      const lines = tree(t, {
        'small/a/b/c/four-deep.bin': 3,
        'big/one.bin': 5,
        'Thing.app/Contents/MacOS/thing': 2,
        'tiny/under-the-cut-off.bin': 0.25,
      });
      assert.deepEqual(lines.map((line) => line.split(' | ')[0]), ['big', 'small', '  a', '    b', 'Thing.app']);
    });

    it('lists private folders by name without counting what is in them', (t) => {
      const lines = tree(t, {
        'Users/alice/Projects/code.bin': 3,
        'Users/alice/Documents/secret.bin': 9,
        'Users/alice/Music/song.bin': 9,
        'Users/alice/Library/Containers/app/data.bin': 9,
        'Users/alice/Library/Caches/cache.bin': 2,
        'Users/alice/Pictures/Photos Library.photoslibrary/photo.bin': 9,
        'Users/alice/Pictures/mine.bin': 2,
      });
      assert.deepEqual(lines, [
        'Users | ≥ 7 MB',
        '  alice | ≥ 7 MB',
        '    Projects | 3 MB',
        '    Library | ≥ 2 MB',
        '    Pictures | ≥ 2 MB',
        '    Documents | private',
        '    Music | private',
      ]);
    });
  });
});

// Offline: menubar-stats' scripts compile; MacStats draws its menu bar items to PNGs, groups and
// weights the Mac's temperature sensors, and lists the disk's spaces and folders; setup.sh orders
// the items as SKILL.md says. Nothing is installed, no setting is written and no app is started or quit.
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { after, before, describe, it } from 'node:test';
import { ROOT, runOk, tempDir } from './helpers.mjs';

const SKILL = join(ROOT, 'plugins/general/skills/menubar-stats');
const SCRIPTS = join(SKILL, 'scripts');
const SOURCES = readdirSync(join(SCRIPTS, 'macstats')).filter((name) => name.endsWith('.swift')).map((name) => join(SCRIPTS, 'macstats', name));
const FILES = ['SKILL.md', 'scripts/setup.sh', 'scripts/menubar-order.swift', ...SOURCES.map((path) => path.slice(SKILL.length + 1))];
const skillText = readFileSync(join(SKILL, 'SKILL.md'), 'utf8');
const setup = readFileSync(join(SCRIPTS, 'setup.sh'), 'utf8');

describe('menubar-stats', () => {
  it('names only scripts that exist', () => {
    const paths = [...skillText.matchAll(/`(scripts\/[^`\s…*]+)`/g)].map((m) => m[1]);
    assert.ok(paths.includes('scripts/setup.sh'), 'SKILL.md points at scripts/setup.sh');
    for (const path of paths) assert.ok(existsSync(join(SKILL, path)), `${path} exists`);
  });

  it('carries no machine paths, and credits Stats beside the code adapted from it', () => {
    for (const file of FILES) {
      assert.doesNotMatch(readFileSync(join(SKILL, file), 'utf8'), /\/Users\/|\.agents\/skills|AGENTS\.md/, `${file} assumes no host machine or repository`);
    }
    assert.match(readFileSync(join(SCRIPTS, 'macstats/LICENSE-stats.txt'), 'utf8'), /MIT License[\s\S]*Serhiy Mytrovtsiy/);
    for (const file of ['SMC.swift', 'SensorCatalog.swift']) {
      assert.match(readFileSync(join(SCRIPTS, 'macstats', file), 'utf8'), /LICENSE-stats\.txt/, `${file} credits Stats`);
    }
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
    const order = ['CPU_mini', 'GPU_mini', 'RAM_mini', 'MacStatsTemp', 'MacStatsDisk', 'Item-0'].map(position);
    for (let i = 1; i < order.length; i++) assert.ok(order[i - 1] > order[i], 'a larger number sits further left');
  });

  it('typechecks the menu bar order script', () => {
    runOk('xcrun', ['swiftc', '-typecheck', join(SCRIPTS, 'menubar-order.swift')]);
  });

  describe('MacStats', () => {
    let binary;
    before(() => {
      binary = join(mkdtempSync(join(tmpdir(), 'skills-general-macstats-')), 'MacStats');
      runOk('xcrun', ['swiftc', '-O', ...SOURCES, '-o', binary], { timeout: 300_000 });
    });
    after(() => rmSync(dirname(binary), { recursive: true, force: true }));

    const isPng = (path) => assert.deepEqual([...readFileSync(path).subarray(0, 4)], [0x89, 0x50, 0x4e, 0x47], 'writes a PNG');

    it('renders the Disk item as used/total GB', (t) => {
      const png = join(tempDir(t, 'macstats-png'), 'disk.png');
      assert.match(runOk(binary, ['--render', 'disk', png]).stdout, /^\d+\.\d\/\d+\.\d GB\n$/);
      isPng(png);
    });

    it('renders the Temp item as CPU°/GPU°', (t) => {
      const png = join(tempDir(t, 'macstats-png'), 'temp.png');
      assert.match(runOk(binary, ['--render', 'temp', png]).stdout, /^(\d+°|–)\/(\d+°|–)\n$/);
      isPng(png);
    });

    it('weights a group toward its hottest sensor', () => {
      const weigh = (...values) => Number(runOk(binary, ['--weigh', ...values.map(String)]).stdout);
      assert.equal(weigh(50), 50);
      assert.equal(weigh(50, 50, 50), 50);
      // One sensor 3 °C cooler counts e^-1 ≈ 37%: (53 + 50 * 0.368) / 1.368 ≈ 52.19.
      assert.equal(weigh(53, 50), 52.19);
      const values = [49.8, 53.0, 51.85, 51.83, 49.76, 49.88, 52.4, 50.26, 50.37];
      const mean = values.reduce((a, b) => a + b) / values.length;
      const weighted = weigh(...values);
      assert.ok(weighted > mean && weighted < Math.max(...values), 'between the average and the hottest');
    });

    it('lists each part of the Mac once, with no numbered sensors left', () => {
      const lines = runOk(binary, ['--sensors']).stdout.trim().split('\n');
      const start = lines.indexOf('Temperature');
      assert.ok(start >= 0, 'has a Temperature section');
      const rows = [];
      for (const line of lines.slice(start + 1)) {
        if (!line.includes('\t')) break;
        rows.push(line.split('\t'));
      }
      assert.ok(rows.length > 0, 'has temperature rows');
      const names = rows.map(([name]) => name);
      assert.equal(new Set(names).size, names.length, 'each part appears once');
      for (const name of names) assert.doesNotMatch(name, /( \d+| [A-Z]| \([A-Z0-9]\))$/, `${name} is not a numbered sensor`);
      const celsius = rows.map(([, value]) => Number(value));
      for (let i = 1; i < celsius.length; i++) assert.ok(celsius[i - 1] >= celsius[i], 'hottest first');
      if (process.arch === 'arm64') {
        assert.ok(names.some((name) => /^CPU (performance|efficiency) cores$/.test(name)), 'CPU cores are grouped');
        assert.ok(names.includes('GPU'), 'GPU sensors are grouped');
      }
    });

    it('gives every Disk Spaces row under Used a colour, biggest first, Free last', () => {
      const rows = runOk(binary, ['--legend']).stdout.trim().split('\n').map((line) => line.split('\t'));
      assert.deepEqual(rows.map(([title]) => title).sort(),
        ['Free', 'Purgeable', 'macOS system', 'my apps / files', 'other', 'recovery', 'swap', 'update/boot']);
      for (const [title, color] of rows) assert.ok(color, `${title} has a colour`);
      assert.equal(rows.at(-1)[0], 'Free', 'Free is always last');
      const sizes = rows.slice(0, -1).map(([, , bytes]) => Number(bytes));
      for (let i = 1; i < sizes.length; i++) assert.ok(sizes[i - 1] >= sizes[i], 'the rest go biggest first');
    });

    it('lists the disk\'s five spaces in order', () => {
      const titles = runOk(binary, ['--spaces']).stdout.trim().split('\n').map((line) => line.split('\t')[0]);
      assert.deepEqual(titles, ['macOS system', 'update/boot', 'recovery', 'swap', 'my apps / files']);
    });

    const tree = (t, files) => {
      const root = tempDir(t, 'macstats-tree');
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

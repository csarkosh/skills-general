// Offline: menubar-stats' scripts compile; MacStats draws its menu bar items to PNGs, groups and
// weights the Mac's temperature sensors, and lists the disk's spaces and folders; setup.sh orders
// the items as SKILL.md says. Nothing is installed, no setting is written and no app is started or quit.
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir, totalmem } from 'node:os';
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
    const order = ['MacStatsCPU', 'MacStatsGPU', 'MacStatsRAM', 'MacStatsTemp', 'MacStatsDisk', 'Item-0'].map(position);
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

    it('renders the CPU item as its usage, as wide for any value', (t) => {
      const png = join(tempDir(t, 'macstats-png'), 'cpu.png');
      assert.match(runOk(binary, ['--render', 'cpu', png]).stdout, /^\d+%\n$/);
      isPng(png);
      // The item is as wide as "100%" whatever it shows, so the items beside it never shift.
      const width = (file) => readFileSync(file).readUInt32BE(16);
      const ram = join(tempDir(t, 'macstats-png'), 'ram.png');
      runOk(binary, ['--render', 'ram', ram]);
      assert.equal(width(png), width(ram), 'the CPU and RAM items are as wide, whatever their values');
    });

    it('reads the CPU: System, User and Idle add up, each core type, load, clock speeds, uptime and processes', () => {
      const lines = runOk(binary, ['--cpu'], { timeout: 30_000 }).stdout.trim().split('\n');
      const value = (title) => lines.find((line) => line.startsWith(`${title}\t`))?.split('\t').slice(1);
      const percent = (title) => Number(value(title)[0].replace('%', ''));
      const sum = percent('System') + percent('User') + percent('Idle');
      assert.ok(Math.abs(sum - 100) <= 2, `System, User and Idle add up to 100% (${sum})`);
      for (const title of ['1 minute', '5 minutes', '15 minutes']) assert.ok(Number(value(title)[0]) >= 0, `${title} load`);
      assert.match(value('Uptime')[0], /\d/);
      if (process.arch === 'arm64') {
        const types = ['Efficiency cores', 'Performance cores'];
        const counts = types.map((title) => lines.filter((line) => line.startsWith(`${title}\t`)).at(-1).split('\t'));
        assert.equal(counts.reduce((total, [, count]) => total + Number(count), 0), Number(runOk('sysctl', ['-n', 'hw.ncpu']).stdout),
          'the core types hold every core');
        for (const [title, , steps] of counts) {
          const mhz = steps.split(',').map((step) => Number.parseInt(step, 10));
          assert.ok(mhz.length > 1 && mhz.every((step, i) => step > 0 && (i === 0 || step >= mhz[i - 1])), `${title}' clock steps rise`);
          const speed = Number.parseInt(lines.filter((line) => line.startsWith(`${title}\t`))[1].split('\t')[1], 10);
          assert.ok(speed >= mhz[0] && speed <= mhz.at(-1), `${title}' speed (${speed} MHz) is within its steps`);
        }
      }
      const processes = lines.slice(lines.indexOf('Top processes') + 1).map((line) => Number(line.split('\t')[1].replace('%', '')));
      assert.ok(processes.length > 0, 'lists processes');
      for (let i = 1; i < processes.length; i++) assert.ok(processes[i - 1] >= processes[i], 'the busiest first');
    });

    it('renders the GPU item as its utilization', (t) => {
      const png = join(tempDir(t, 'macstats-png'), 'gpu.png');
      assert.match(runOk(binary, ['--render', 'gpu', png]).stdout, /^\d+%\n$/);
      isPng(png);
    });

    it('reads the GPU: utilization, renderer, tiler, memory, model and the apps using it', () => {
      const lines = runOk(binary, ['--gpu'], { timeout: 30_000 }).stdout.trim().split('\n');
      const value = (title) => lines.find((line) => line.startsWith(`${title}\t`))?.split('\t').slice(1);
      for (const title of ['Utilization', 'Renderer', 'Tiler']) {
        const percent = Number(value(title)[0].replace('%', ''));
        assert.ok(percent >= 0 && percent <= 100, `${title} is a percentage`);
      }
      const [inUse, allocated, limit] = value('Memory').map(Number);
      assert.ok(inUse >= 0 && inUse <= allocated, 'GPU memory in use is within what is set aside');
      assert.ok(limit > 0 && limit <= totalmem(), 'the GPU memory limit is at most the Mac\'s memory');
      assert.ok(value('Model')[0].length > 0, 'names the GPU');
      const apps = lines.slice(lines.indexOf('Top GPU apps') + 1).map((line) => Number(line.split('\t')[1].replace('%', '')));
      for (let i = 1; i < apps.length; i++) assert.ok(apps[i - 1] >= apps[i], 'the busiest app first');
    });

    it('renders the RAM item as the share of memory in use', (t) => {
      const png = join(tempDir(t, 'macstats-png'), 'ram.png');
      assert.match(runOk(binary, ['--render', 'ram', png]).stdout, /^\d+%\n$/);
      isPng(png);
    });

    it('splits memory into App, Wired, Compressed and Free, and lists the top processes', () => {
      const lines = runOk(binary, ['--memory']).stdout.trim().split('\n');
      const row = (title) => Number(lines.find((line) => line.startsWith(`${title}\t`)).split('\t')[2]);
      const parts = ['App', 'Wired', 'Compressed', 'Free'];
      const usage = lines.slice(lines.indexOf('Usage') + 1, lines.indexOf('Top processes')).map((line) => line.split('\t')[0]);
      assert.deepEqual(usage, ['Used', ...parts, 'Swap', 'Total'], 'the rows in Stats\' order');
      const close = (a, b) => Math.abs(a - b) <= 0.01 * row('Total');
      assert.ok(close(row('App') + row('Wired') + row('Compressed'), row('Used')), 'App, Wired and Compressed make Used');
      assert.ok(close(row('Used') + row('Free'), row('Total')), 'Used and Free make all memory');
      const processes = lines.slice(lines.indexOf('Top processes') + 1).map((line) => Number(line.split('\t')[2]));
      assert.ok(processes.length > 0 && processes.length <= 8, 'up to eight processes');
      for (let i = 1; i < processes.length; i++) assert.ok(processes[i - 1] >= processes[i], 'biggest first');
    });

    it('renders the Disk item as used/total GB', (t) => {
      const png = join(tempDir(t, 'macstats-png'), 'disk.png');
      assert.match(runOk(binary, ['--render', 'disk', png]).stdout, /^\d+\.\d\/\d+\.\d GB\n$/);
      isPng(png);
    });

    it('renders the Temp item as the hottest part\'s temperature', (t) => {
      const png = join(tempDir(t, 'macstats-png'), 'temp.png');
      assert.match(runOk(binary, ['--render', 'temp', png]).stdout, /^(\d+°|–)\n$/);
      isPng(png);
    });

    it('rates power use by this Mac\'s tiers', () => {
      const level = (watts) => runOk(binary, ['--power-level', String(watts)]).stdout.trim();
      // The M4 MacBook Air: normal below 10 W, moderate below 20 W, high from 20 W.
      if (process.arch === 'arm64' && /Apple M\d+$/.test(runOk('sysctl', ['-n', 'machdep.cpu.brand_string']).stdout.trim())) {
        assert.deepEqual([9.9, 10, 19.9, 20, 31].map(level), ['normal', 'moderate', 'moderate', 'high', 'high']);
      }
      const gauges = runOk(binary, ['--sensors']).stdout.split('\n');
      const hottest = gauges.find((line) => line.startsWith('Hottest\t'));
      if (hottest) {
        const temperatures = gauges.slice(gauges.indexOf('Temperature') + 1);
        assert.equal(hottest.split('\t')[1], temperatures[0].split('\t')[0], 'the gauge shows the top Temperature row');
      }
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

    it('colours each temperature row by that part\'s own limits', () => {
      const heat = (name, celsius) => runOk(binary, ['--heat', name, String(celsius)]).stdout.trim();
      // [row, yellow from, red from]: a chip runs hot by design, a battery and an SSD do not.
      for (const [name, warm, hot] of [['CPU performance cores', 85, 100], ['GPU', 85, 100], ['Battery', 35, 40], ['SSD', 50, 70], ['Wi-Fi', 60, 80]]) {
        assert.equal(heat(name, warm - 0.1), 'green', `${name} below ${warm} °C`);
        assert.equal(heat(name, warm), 'yellow', `${name} at ${warm} °C`);
        assert.equal(heat(name, hot - 0.1), 'yellow', `${name} below ${hot} °C`);
        assert.equal(heat(name, hot), 'red', `${name} at ${hot} °C`);
      }
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

    it('puts voltage, current and power in one plain Power section', () => {
      const lines = runOk(binary, ['--sensors']).stdout.trim().split('\n');
      for (const raw of ['Voltage', 'Current']) assert.ok(!lines.includes(raw), `no separate ${raw} section`);
      const start = lines.indexOf('Power');
      if (start < 0) return; // a Mac without power sensors has no Power section
      const titles = [];
      for (const line of lines.slice(start + 1)) {
        if (!line.includes('\t')) break;
        titles.push(line.split('\t')[0]);
      }
      for (const raw of ['System Total', 'DC In', '12V rail']) assert.ok(!titles.includes(raw), `${raw} is shown in plain words`);
      if (process.arch === 'arm64') assert.equal(titles[0], 'Total', 'what the whole Mac uses comes first');
      const hasBattery = runOk('ioreg', ['-rn', 'AppleSmartBattery']).stdout.includes('AppleRawMaxCapacity');
      if (hasBattery) {
        const row = lines.slice(start + 1).find((line) => line.startsWith('Battery left\t'));
        assert.ok(row, 'a Mac with a battery shows what is left in it');
        assert.match(row.split('\t')[1], /^\d+\.\d\/\d+\.\d Wh \(\d+%\)$/, 'as left/full Wh and the percentage');
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

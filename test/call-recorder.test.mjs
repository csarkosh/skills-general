// Offline: call-recorder's script runs its Python unit tests, explains a missing mlx-whisper
// instead of tracebacking, and carries nothing private. No audio device, model or network is used.
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { ROOT, cleanEnv, run, runOk, tempDir } from './helpers.mjs';

const SKILL = join(ROOT, 'plugins/general/skills/call-recorder');
const CALLREC = join(SKILL, 'scripts/callrec.py');
const FILES = ['SKILL.md', 'scripts/callrec.py', 'scripts/tests/test_callrec.py'];
const skillText = readFileSync(join(SKILL, 'SKILL.md'), 'utf8');

describe('call-recorder', () => {
  it('names only scripts that exist', () => {
    const paths = [...skillText.matchAll(/`(scripts\/[^`\s…]+)`/g)].map((m) => m[1]);
    assert.ok(paths.includes('scripts/callrec.py'), 'SKILL.md points at scripts/callrec.py');
    for (const path of paths) assert.ok(existsSync(join(SKILL, path)), `${path} exists`);
  });

  it('carries no machine paths and no hard-coded interpreter', () => {
    for (const file of FILES) {
      assert.doesNotMatch(readFileSync(join(SKILL, file), 'utf8'), /\/Users\/|\.agents\/skills|AGENTS\.md/, `${file} assumes no host machine or repository`);
    }
    assert.match(readFileSync(CALLREC, 'utf8'), /^#!\/usr\/bin\/env python3\n/);
  });

  it('passes its Python unit tests', () => {
    const { stdout, stderr } = runOk('python3', ['-B', '-m', 'unittest', 'discover', '-s', 'scripts/tests'], { cwd: SKILL });
    assert.match(stdout + stderr, /\nOK\b/);
  });

  it('reports that nothing is recording from a fresh home', (t) => {
    const home = tempDir(t, 'callrec-home');
    const { stdout } = runOk('python3', ['-B', CALLREC, 'status'], { env: cleanEnv({ HOME: home }) });
    assert.match(stdout, /Not recording\./);
  });

  it('asks for mlx-whisper by name when it is not importable', (t) => {
    const env = cleanEnv({ PYTHONPATH: join(ROOT, 'test/fixtures/no-mlx-whisper') });
    const { status, stdout, stderr } = run('python3', ['-B', CALLREC, 'transcribe-file', join(tempDir(t, 'callrec'), 'memo.m4a')], { env });
    assert.notEqual(status, 0);
    assert.doesNotMatch(stdout + stderr, /Traceback/);
    assert.match(stderr, /mlx-whisper is not installed/);
    assert.match(stderr, /pip install mlx-whisper/);
    assert.match(skillText, /pip install mlx-whisper/, 'SKILL.md says so too');
  });
});

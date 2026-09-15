// Shared plumbing for the plugin tests: run a CLI, make throwaway directories, and build the sample
// repository the live tests ask each agent to work in.
import { spawnSync } from 'node:child_process';
import { cpSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = fileURLToPath(new URL('..', import.meta.url));
export const MARKETPLACE = 'csarkosh';
export const SAMPLE_DOC = 'docs/rendering/2026-01-02-sample-doc.md';

// Live tests start a real agent session and spend model tokens. `SKILLS_LIVE=0` (npm run
// test:offline) runs everything else.
export const LIVE = process.env.SKILLS_LIVE !== '0';

export function readJson(path) {
  return JSON.parse(readFileSync(path, 'utf8'));
}

// Runs a command to completion. stdin is closed so an agent CLI never waits on it.
export function run(cmd, args, { cwd, env = cleanEnv(), timeout = 120_000 } = {}) {
  const result = spawnSync(cmd, args, { cwd, env, timeout, input: '', encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
  if (result.error) throw new Error(`${cmd} ${args.join(' ')}: ${result.error.message}`);
  return result;
}

export function runOk(cmd, args, options) {
  const result = run(cmd, args, options);
  if (result.status !== 0) {
    throw new Error(`${cmd} ${args.join(' ')} exited ${result.status}\n${result.stdout}\n${result.stderr}`);
  }
  return result;
}

// Fails the test with a clear message when an agent CLI is not installed, rather than skipping:
// a test that quietly skips proves nothing.
export function requireCli(name) {
  const result = spawnSync(name, ['--version'], { encoding: 'utf8' });
  if (result.error || result.status !== 0) {
    throw new Error(`\`${name}\` is not installed or not on PATH; install it, or run npm run test:offline`);
  }
}

// The environment an agent CLI should see: this process's, minus the variables a parent Claude
// Code session sets, so a test launched from inside Claude Code starts a clean, independent session.
export function cleanEnv(extra = {}) {
  const env = { ...process.env };
  for (const key of Object.keys(env)) {
    if (key.startsWith('CLAUDE_CODE_') || key === 'CLAUDECODE' || key === 'CLAUDE_PID' || key === 'CLAUDE_EFFORT') delete env[key];
  }
  return { ...env, ...extra };
}

export function tempDir(t, label) {
  const dir = mkdtempSync(join(tmpdir(), `skills-general-${label}-`));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

// A git repository named sample-repo holding one dated doc, like the repositories these skills serve.
export function sampleRepo(t) {
  const repo = join(tempDir(t, 'repo'), 'sample-repo');
  mkdirSync(repo);
  cpSync(join(ROOT, 'test/fixtures/sample-repo'), repo, { recursive: true });
  runOk('git', ['init', '-q'], { cwd: repo });
  return repo;
}

export function parseJsonLines(text) {
  return text.split('\n').flatMap((line) => {
    try { return [JSON.parse(line)]; } catch { return []; }
  });
}

export function listFiles(dir) {
  return readdirSync(dir, { withFileTypes: true, recursive: true })
    .filter((entry) => entry.isFile())
    .map((entry) => join(entry.parentPath, entry.name));
}

// The request the live tests send. It names what the user wants, not the skill, so passing also
// proves the agent picks the skill from its description.
export function previewPrompt(outDir) {
  return `Open ${SAMPLE_DOC} as a styled page in Chrome. This is an automated test with no display: `
    + `don't launch a browser (use the no-open option), and write the page into ${outDir}.`;
}

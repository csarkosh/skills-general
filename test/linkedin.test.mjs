// Offline: the linkedin skill keeps the rules every LinkedIn task shares in SKILL.md, where they always
// load, and each task's steps in its own reference file. The old task-specific skill must be gone.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { ROOT } from './helpers.mjs';

const SKILL = join(ROOT, 'plugins/general/skills/linkedin');
const read = (path) => (existsSync(path) ? readFileSync(path, 'utf8') : '');
const skillText = read(join(SKILL, 'SKILL.md'));
const ref = (name) => read(join(SKILL, 'references', name));
const TASKS = ['profile.md', 'messages.md', 'invitations.md', 'notifications.md'];
const OLD_NAME = ['linkedin', 'profile'].join('-');

describe('linkedin', () => {
  it('indexes a reference file per task, and each exists', () => {
    assert.ok(skillText, 'SKILL.md exists');
    for (const task of TASKS) {
      assert.ok(skillText.includes(`\`references/${task}\``), `SKILL.md indexes references/${task}`);
      assert.ok(ref(task), `references/${task} exists`);
    }
  });

  it('keeps the rules every task shares in SKILL.md', () => {
    for (const phrase of ['Share your contact info?', "No, don't share", 'Yes, interested', 'Create a post', '"Reply to {name}"', 'clear yes']) {
      assert.ok(skillText.includes(phrase), `SKILL.md says "${phrase}"`);
    }
    assert.match(skillText, /accepts\s+or\s+ignores\s+an\s+invitation/, 'SKILL.md requires approval before accepting or ignoring an invitation');
  });

  it('profile.md keeps the form traps and shows how to see the profile as a recruiter would', () => {
    for (const phrase of ['Share with your network', 'Update your profile headline', 'Follow this skill', 'Contributors', 'linkedin.com/in/me/', 'public-profile/settings', 'private or incognito window']) {
      assert.ok(ref('profile.md').includes(phrase), `profile.md says "${phrase}"`);
    }
  });

  it('messages.md covers the Other inbox, InMail copies, reading and the Send button', () => {
    for (const phrase of ['Recruiter InMail lands in Other', 'inmail-hit-reply@linkedin.com', 'submit button labelled Send', 'expected sender']) {
      assert.ok(ref('messages.md').includes(phrase), `messages.md says "${phrase}"`);
    }
  });

  it('messages.md warns that opening a thread can send a read receipt', () => {
    assert.match(ref('messages.md'), /read receipts/i, 'messages.md mentions read receipts');
  });

  it('invitations.md reviews in a batch and never connects or says hello', () => {
    for (const phrase of ['Batch review', 'Say hello', 'mutual connections']) {
      assert.ok(ref('invitations.md').includes(phrase), `invitations.md says "${phrase}"`);
    }
    assert.match(ref('invitations.md'), /never press\s+\*\*Connect\*\*/i, 'invitations.md never presses Connect');
  });

  it('invitations.md tells the user what Accept does before the batch review is approved', () => {
    const text = ref('invitations.md');
    const section = text.split('## 3. Batch review')[1]?.split('## 4.')[0] ?? '';
    assert.match(section, /contact info/, 'the batch-review section names contact info');
  });

  it('notifications.md clears the badge, skips people, and acts on nothing', () => {
    for (const phrase of ["Skip items that open a person's profile", 'Never react']) {
      assert.ok(ref('notifications.md').includes(phrase), `notifications.md says "${phrase}"`);
    }
    assert.match(ref('notifications.md'), /clears the badge/, 'notifications.md says opening clears the badge');
  });

  it('notifications.md warns that a name or avatar link opens a profile', () => {
    assert.match(ref('notifications.md'), /\/in\//, 'notifications.md names the /in/ profile link pattern');
  });

  it('notifications.md skips opening items for a summary-only request', () => {
    assert.match(ref('notifications.md'), /only for a summary/, 'notifications.md covers a summary-only request');
  });

  it('leaves no mention of the old skill name outside docs/', () => {
    const tracked = execFileSync('git', ['ls-files'], { cwd: ROOT, encoding: 'utf8' })
      .split('\n')
      .filter((path) => path && !path.startsWith('docs/'))
      .filter((path) => statSync(join(ROOT, path)).isFile()); // skip directory symlinks such as .claude/skills
    const offenders = tracked.filter((path) => readFileSync(join(ROOT, path), 'utf8').includes(OLD_NAME));
    assert.deepEqual(offenders, [], `files still mention ${OLD_NAME}`);
  });
});

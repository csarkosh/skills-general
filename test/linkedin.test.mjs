// Offline: the linkedin skill keeps the rules every LinkedIn task shares in SKILL.md, where they always
// load, and each task's steps in its own reference file. The old task-specific skill must be gone.
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { ROOT } from './helpers.mjs';

const SKILL = join(ROOT, 'plugins/general/skills/linkedin');
const read = (path) => (existsSync(path) ? readFileSync(path, 'utf8') : '');
const skillText = read(join(SKILL, 'SKILL.md'));
const ref = (name) => read(join(SKILL, 'references', name));
const TASKS = ['profile.md', 'messages.md', 'invitations.md', 'notifications.md'];
const OLD_NAME = ['linkedin', 'profile'].join('-');

function filesUnder(dir) {
  return readdirSync(dir).flatMap((entry) => {
    if (['.git', 'node_modules', 'docs', '.superpowers'].includes(entry)) return [];
    const path = join(dir, entry);
    return statSync(path).isDirectory() ? filesUnder(path) : [path];
  });
}

describe('linkedin', () => {
  it('indexes a reference file per task, and each exists', () => {
    assert.ok(skillText, 'SKILL.md exists');
    for (const task of TASKS) {
      assert.ok(skillText.includes(`\`references/${task}\``), `SKILL.md indexes references/${task}`);
      assert.ok(ref(task), `references/${task} exists`);
    }
  });

  it('keeps the rules every task shares in SKILL.md', () => {
    for (const phrase of ['Share your contact info?', "No, don't share", 'Yes, interested', 'Create a post', 'Reply to', 'clear yes', 'viewed their profile']) {
      assert.ok(skillText.includes(phrase), `SKILL.md says "${phrase}"`);
    }
  });

  it('profile.md keeps the form traps and shows how to see the profile as a recruiter would', () => {
    for (const phrase of ['Share with your network', 'Update your profile headline', 'Follow this skill', 'Contributors', 'linkedin.com/in/me/', 'public-profile/settings', 'private or incognito window']) {
      assert.ok(ref('profile.md').includes(phrase), `profile.md says "${phrase}"`);
    }
  });

  it('messages.md covers the Other inbox, InMail copies, reading and the Send button', () => {
    for (const phrase of ['Other', 'inmail-hit-reply@linkedin.com', 'submit button labelled Send', 'expected sender']) {
      assert.ok(ref('messages.md').includes(phrase), `messages.md says "${phrase}"`);
    }
  });

  it('invitations.md reviews in a batch and never connects or says hello', () => {
    for (const phrase of ['Batch review', 'Say hello', 'Connect', 'mutual connections']) {
      assert.ok(ref('invitations.md').includes(phrase), `invitations.md says "${phrase}"`);
    }
  });

  it('notifications.md clears the badge, skips people, and acts on nothing', () => {
    for (const phrase of ['clears the badge', 'profile', 'Never react']) {
      assert.ok(ref('notifications.md').includes(phrase), `notifications.md says "${phrase}"`);
    }
  });

  it('leaves no mention of the old skill name outside docs/', () => {
    const offenders = filesUnder(ROOT).filter((path) => readFileSync(path, 'utf8').includes(OLD_NAME));
    assert.deepEqual(offenders, [], `files still mention ${OLD_NAME}`);
  });
});

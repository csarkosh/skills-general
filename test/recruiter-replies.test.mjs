// Offline: recruiter-replies keeps every user's preferences out of this public repository. The skill
// ships a blank template and finds the user's own file through a documented hook.
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { ROOT } from './helpers.mjs';

const SKILL = join(ROOT, 'plugins/general/skills/recruiter-replies');
const read = (path) => (existsSync(path) ? readFileSync(path, 'utf8') : '');
const skillText = read(join(SKILL, 'SKILL.md'));
const template = read(join(SKILL, 'references/preferences-template.md'));

describe('recruiter-replies', () => {
  it('ships a preferences template with its five sections', () => {
    assert.ok(template, 'references/preferences-template.md exists');
    for (const heading of ['## Stance', '## Scope', '## Criteria', '## Templates', '## Log']) {
      assert.match(template, new RegExp(`^${heading}$`, 'm'), `template has ${heading}`);
    }
    assert.match(template, /Profile changed on: <fill in: /, 'Scope asks when the profile last changed');
    assert.match(template, /^\| Date \| Channel \| Person \| Company \| Role \| Fit \| Reply \| Follow up \|$/m);
  });

  it('has a template per reply type, including a clarifying question', () => {
    for (const fit of ['Promising', 'Needs info', 'Poor fit']) {
      assert.match(template, new RegExp(`^\\*\\*${fit}\\*\\*`, 'm'), `template has a ${fit} reply`);
    }
    const needsInfo = template.split('\n**Needs info**\n')[1].split('\n**Poor fit**')[0];
    assert.match(needsInfo, /\{question\}/, 'the Needs info reply asks {question}');
  });

  it('leaves every personal choice in the template for the user to fill in', () => {
    for (const fit of ['Promising', 'Poor fit']) {
      const row = template.split('\n').find((line) => line.startsWith(`| **${fit}** |`));
      assert.ok(row, `template has a ${fit} row`);
      assert.match(row, /<fill in: /, `${fit} is a placeholder, not a value`);
    }
    assert.doesNotMatch(template, /[\w.+-]+@[\w-]+\.[\w.]+/, 'no email address');
    const logRows = template.split('## Log')[1].split('\n').filter((line) => line.startsWith('|'));
    assert.equal(logRows.length, 2, 'the log is only a header and a divider');
  });

  it('documents where it finds the user\'s preferences, in order', () => {
    assert.ok(skillText, 'SKILL.md exists');
    const path = skillText.indexOf('a path the user names');
    const env = skillText.indexOf('RECRUITER_PREFS');
    const fallback = skillText.indexOf('~/.config/recruiter-replies/preferences.md');
    assert.ok(path >= 0 && env > path && fallback > env, 'path, then $RECRUITER_PREFS, then the default file');
    assert.match(skillText, /inside a git repository/, 'refuses to save preferences inside a repository');
  });

  it('never sends without approval of the exact text, or shares contact info', () => {
    assert.match(skillText, /exact text/);
    assert.match(skillText, /Yes, interested/, 'warns about one-tap InMail replies');
    assert.match(skillText, /Share your contact info\?/, 'names LinkedIn\'s contact-info dialog');
    assert.match(skillText, /No, don't share/, 'declines it');
  });

  it('carries the lessons from real runs', () => {
    assert.match(skillText, /-from:inmail-hit-reply@linkedin\.com/, 'Gmail search excludes LinkedIn\'s InMail copies');
    assert.match(skillText, /stale cutoff/, 'old poor fits are proposed as no reply');
    assert.match(skillText, /Profile changed on/, 'outreach aimed at the old profile is stale');
    assert.match(skillText, /Group by company/, 'several recruiters for one company become one row');
    assert.match(skillText, /expected sender/, 'reads a thread only once its header shows the right sender');
    assert.match(skillText, /Not interested/, 'a fitting role the user does not want gets a decline');
  });

  it('takes its LinkedIn mechanics from the linkedin skill, and keeps its own safety table', () => {
    assert.match(skillText, /`\.\.\/linkedin\/references\/messages\.md`/, 'links the shared messages reference');
    assert.ok(existsSync(join(SKILL, '../linkedin/references/messages.md')), 'the linked file exists');
    const safety = skillText.split('## Safety rules')[1] ?? '';
    assert.match(safety, /Share your contact info\?/, 'its own safety table still names the contact-info dialog');
  });
});

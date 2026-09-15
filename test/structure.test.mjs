// Offline checks on the repository itself: both marketplaces agree, every skill is well formed, and
// skills shared with Codex use nothing that only Claude Code has.
import assert from 'node:assert/strict';
import { existsSync, lstatSync, readFileSync, readdirSync, readlinkSync } from 'node:fs';
import { join } from 'node:path';
import { describe, it } from 'node:test';
import { ROOT, readJson } from './helpers.mjs';

const claudeMarketplace = readJson(join(ROOT, '.claude-plugin/marketplace.json'));
const codexMarketplace = readJson(join(ROOT, '.agents/plugins/marketplace.json'));
const claudePlugins = claudeMarketplace.plugins.map((p) => ({ name: p.name, dir: join(ROOT, p.source) }));
const codexPlugins = codexMarketplace.plugins.map((p) => ({ name: p.name, dir: join(ROOT, p.source.path) }));

// Names of tools and variables that exist only in Claude Code. A skill in a plugin Codex installs
// must not depend on them.
const CLAUDE_ONLY = [/\bAskUserQuestion\b/, /\bCLAUDE_PLUGIN_ROOT\b/, /\bArtifact tool\b/, /\bTodoWrite\b/, /\bSubagentHandback\b/];

function skillsOf(pluginDir) {
  const dir = join(pluginDir, 'skills');
  return readdirSync(dir, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => ({ name: entry.name, dir: join(dir, entry.name), text: readFileSync(join(dir, entry.name, 'SKILL.md'), 'utf8') }));
}

function frontmatter(text) {
  const match = /^---\n([\s\S]*?)\n---\n/.exec(text);
  assert.ok(match, 'SKILL.md starts with a --- frontmatter block');
  return Object.fromEntries(match[1].split('\n').map((line) => {
    const colon = line.indexOf(':');
    return [line.slice(0, colon).trim(), line.slice(colon + 1).trim()];
  }));
}

describe('marketplaces', () => {
  it('share one marketplace name', () => {
    assert.equal(claudeMarketplace.name, 'csarkosh');
    assert.equal(codexMarketplace.name, claudeMarketplace.name);
  });

  it('offer Codex only plugins that Claude Code also offers, from the same directory', () => {
    for (const plugin of codexPlugins) {
      const twin = claudePlugins.find((p) => p.name === plugin.name);
      assert.ok(twin, `${plugin.name} is in the Codex marketplace but not the Claude Code one`);
      assert.equal(twin.dir, plugin.dir);
    }
  });

  it('give each plugin a manifest for every agent that lists it, with matching name and version', () => {
    for (const plugin of claudePlugins) {
      const claude = readJson(join(plugin.dir, '.claude-plugin/plugin.json'));
      assert.equal(claude.name, plugin.name);
      const codexPath = join(plugin.dir, '.codex-plugin/plugin.json');
      const listedForCodex = codexPlugins.some((p) => p.name === plugin.name);
      assert.equal(existsSync(codexPath), listedForCodex, `${plugin.name}: a Codex manifest exists exactly when Codex lists the plugin`);
      if (listedForCodex) {
        const codex = readJson(codexPath);
        assert.equal(codex.name, plugin.name);
        assert.equal(codex.version, claude.version, `${plugin.name}: both manifests carry the same version`);
      }
    }
  });
});

describe('skills', () => {
  for (const plugin of claudePlugins) {
    for (const skill of skillsOf(plugin.dir)) {
      it(`${plugin.name}:${skill.name} has a valid SKILL.md`, () => {
        const meta = frontmatter(skill.text);
        assert.equal(meta.name, skill.name, 'frontmatter name matches the directory');
        assert.match(meta.name, /^[a-z0-9]+(-[a-z0-9]+)*$/);
        assert.match(meta.description, /^Use when /, 'description says when to use the skill');
        assert.ok(meta.description.length <= 1024, 'description fits the 1024-character limit');
      });

      it(`${plugin.name}:${skill.name} references only files that exist`, () => {
        const paths = [...skill.text.matchAll(/`((?:scripts|assets|references)\/[^`\s…]+)`/g)].map((m) => m[1]);
        for (const path of paths) assert.ok(existsSync(join(skill.dir, path)), `${path} exists in ${skill.name}`);
      });

      if (codexPlugins.some((p) => p.name === plugin.name)) {
        it(`${plugin.name}:${skill.name} uses nothing only Claude Code has`, () => {
          for (const pattern of CLAUDE_ONLY) assert.doesNotMatch(skill.text, pattern);
        });
      }
    }
  }
});

describe('agent setup', () => {
  it('points .claude/skills at .agents/skills', () => {
    assert.ok(lstatSync(join(ROOT, '.claude/skills')).isSymbolicLink());
    assert.equal(readlinkSync(join(ROOT, '.claude/skills')), '../.agents/skills');
  });

  it('has CLAUDE.md import AGENTS.md', () => {
    assert.match(readFileSync(join(ROOT, 'CLAUDE.md'), 'utf8'), /^@AGENTS\.md$/m);
  });
});

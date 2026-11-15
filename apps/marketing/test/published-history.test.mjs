import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { publishedHistory } from '../src/lib/published-history.mjs';
import { groups, shown } from '../src/data/catalog.ts';

const release = version => ({version, build: '202611121130', channel: 'stable', date: '2026-11-12T11:30:00Z'});
const stamp = version => [`/notes/${version}.md`, 'Source: `abcdef0`. Build: `202611061458`. Channel: stable.'];

test('retiring downloads preserves 5+ shipped versions and their dates', () => {
  const versions = ['0.1.0','0.1.2','0.1.3','0.1.4','0.1.5','0.1.6','0.1.7','0.1.8'];
  const feed = versions.slice(-4).map(release);
  const history = publishedHistory(feed, Object.fromEntries(versions.map(stamp)));
  assert.deepEqual([...history.keys()], [...versions].reverse());
  assert.equal(history.get('0.1.0').date, '2026-11-06T14:58:00Z');
  assert.equal(history.get('0.1.8'), feed.at(-1));
});

test('future, unstamped and nightly notes cannot publish; semver comparison is numeric', () => {
  const entries = Object.fromEntries(['0.1.2','0.1.9','0.1.10','0.1.11'].map(stamp));
  entries['/notes/0.1.3.md'] = '# Unpublished notes';
  entries['/notes/0.1.4.md'] = stamp('0.1.4')[1].replace('stable.', 'nightly.');
  const history = publishedHistory([release('0.1.10'), {...release('0.1.11'), channel:'nightly'}], entries);
  assert.deepEqual([...history.keys()], ['0.1.10','0.1.9','0.1.2']);
  assert.equal(publishedHistory([], entries).size, 0);
  assert.equal(shown({title:'Future', line:'', since:'next'}, history, false), false);
});

test('every shipped catalogue since value survives the four-item feed', () => {
  const dir = new URL('../src/content/changelog/', import.meta.url);
  const entries = Object.fromEntries(readdirSync(dir).filter(n => n.endsWith('.md')).map(n => [`/notes/${n}`, readFileSync(new URL(n, dir),'utf8')]));
  const history = publishedHistory(['0.1.5','0.1.6','0.1.7','0.1.8'].map(release), entries);
  for (const since of new Set(groups.flatMap(g => g.features.map(f => f.since)))) {
    if (/^0\.1\.[0-8]$/.test(since)) assert.ok(shown({title:since, line:'', since}, history, false), since);
  }
  assert.equal(shown({title:'Expired', line:'', since:'0.1.0', until:'0.1.4'}, history, false), false);
  assert.equal(shown({title:'Replacement', line:'', since:'0.1.0', from:'0.1.4'}, history, false), true);
  assert.equal(shown({title:'Future', line:'', since:'next'}, history, false), false);
});

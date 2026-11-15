// Publication history outlives Sparkle's retained download window. A stamped changelog entry is
// eligible only once Stable has reached its version; staged future notes never publish themselves.
/** @param {string} a @param {string} b */
export function compareVersions(a, b) {
  const x = a.split('.').map(Number), y = b.split('.').map(Number);
  return x[0] - y[0] || x[1] - y[1] || x[2] - y[2];
}

/**
 * @param {import('./release').Version[]} feed
 * @param {Record<string, string>} entries
 * @returns {Map<string, import('./release').Version>}
 */
export function publishedHistory(feed, entries) {
  const stable = feed.filter(v => v.channel === 'stable');
  const latest = stable.map(v => v.version).sort(compareVersions).at(-1);
  if (!latest) return new Map();
  const history = new Map(stable.map(v => [v.version, v]));
  for (const [path, markdown] of Object.entries(entries)) {
    const version = path.match(/\/(\d+\.\d+\.\d+)\.md$/)?.[1];
    const build = markdown.match(/^Source: `[0-9a-f]{7,40}`\. Build: `(\d{12})`\. Channel: stable\.$/m)?.[1];
    if (!version || !build || compareVersions(version, latest) > 0 || history.has(version)) continue;
    history.set(version, {
      version, build, channel: 'stable',
      date: `${build.slice(0,4)}-${build.slice(4,6)}-${build.slice(6,8)}T${build.slice(8,10)}:${build.slice(10,12)}:00Z`,
      notes: `/changelog#v${version}`,
    });
  }
  return new Map([...history].sort(([a], [b]) => compareVersions(b, a)));
}

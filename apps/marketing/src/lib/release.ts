// The latest stable release, read once at build time from the public feed (the same feeds/latest.json that
// /download and installed copies use). If the feed can't be reached the page still builds, with the release it
// shipped with.
const FEED = "https://hpqylr02za4pig6a.public.blob.vercel-storage.com/feeds/latest.json";

export interface Release {
  version: string;
  build: string;
  size: number;
  minimumMacOS: string;
  notes: string; // the release notes, on aircbrowser.com (redirects to the immutable Blob copy)
}

const shipped: Release = {
  version: "0.1.0",
  build: "202611061458",
  size: 189_786_890,
  minimumMacOS: "14.0",
  notes: "/releases/0.1.0/202611061458/release-notes.html",
};

let cache: Release | undefined;

export async function getRelease(): Promise<Release> {
  if (cache) return cache;
  try {
    const res = await fetch(FEED, { signal: AbortSignal.timeout(5000) });
    if (!res.ok) throw new Error(String(res.status));
    const j = (await res.json()) as { version: string; build: string; size: number; minimumMacOS: string };
    cache = {
      version: j.version,
      build: j.build,
      size: j.size,
      minimumMacOS: j.minimumMacOS,
      notes: `/releases/${j.version}/${j.build}/release-notes.html`,
    };
  } catch {
    cache = shipped;
  }
  return cache;
}

// 189786890 -> "190 MB"
export const megabytes = (bytes: number) => `${Math.round(bytes / 1_000_000)} MB`;
// "14.0" -> "macOS 14"
export const macOS = (v: string) => `macOS ${v.replace(/\.0$/, "")}`;

// Every published version, from the Sparkle feed (feeds/appcast.xml: all public entries, tagged stable or nightly),
// plus the latest nightly's manifest when one exists. Read at build time; /versions refreshes them in the browser.
const APPCAST = "https://hpqylr02za4pig6a.public.blob.vercel-storage.com/feeds/appcast.xml";
const NIGHTLY = "https://hpqylr02za4pig6a.public.blob.vercel-storage.com/feeds/nightly-latest.json";

export interface Version {
  version: string;
  build: string;
  channel: string;
  date: string; // from the build number: 202611061458 -> 2026-11-06T14:58:00Z
  notes?: string;
  zip?: string;
  zipSize?: number;
  minimumMacOS?: string;
}

export const buildDate = (build: string) =>
  /^\d{12}$/.test(build)
    ? `${build.slice(0, 4)}-${build.slice(4, 6)}-${build.slice(6, 8)}T${build.slice(8, 10)}:${build.slice(10, 12)}:00Z`
    : "";

// The feed's items, by regular expression (it's small and machine-written; the browser uses DOMParser instead).
export function parseAppcast(xml: string): Version[] {
  const tag = (item: string, name: string) => item.match(new RegExp(`<${name}>([^<]*)</${name}>`))?.[1];
  return [...xml.matchAll(/<item>([\s\S]*?)<\/item>/g)]
    .map(([, item]) => {
      const build = tag(item, "sparkle:version") ?? "";
      const enc = item.match(/<enclosure[^>]*url="([^"]+)"[^>]*length="(\d+)"/);
      return {
        version: tag(item, "sparkle:shortVersionString") ?? "",
        build,
        channel: tag(item, "sparkle:channel") ?? "stable",
        date: buildDate(build),
        notes: tag(item, "sparkle:releaseNotesLink")?.replace("https://aircbrowser.com", ""),
        zip: enc?.[1]?.replace("https://aircbrowser.com", ""),
        zipSize: enc ? Number(enc[2]) : undefined,
        minimumMacOS: tag(item, "sparkle:minimumSystemVersion"),
      };
    })
    .sort((a, b) => b.build.localeCompare(a.build));
}

export interface Nightly {
  version: string;
  build: string;
  date: string;
  url: string;
  size: number;
}

export async function getVersions(): Promise<{ all: Version[]; nightly?: Nightly }> {
  let all: Version[] = [];
  let nightly: Nightly | undefined;
  try {
    const r = await fetch(APPCAST, { signal: AbortSignal.timeout(5000) });
    if (r.ok) all = parseAppcast(await r.text());
  } catch {}
  try {
    const r = await fetch(NIGHTLY, { signal: AbortSignal.timeout(5000) });
    if (r.ok) {
      const j = (await r.json()) as { version: string; build: string; url: string; size: number };
      nightly = { ...j, date: buildDate(j.build), url: new URL(j.url).pathname };
    }
  } catch {}
  if (!all.length) {
    const s = await getRelease();
    all = [{ version: s.version, build: s.build, channel: "stable", date: buildDate(s.build), notes: s.notes, minimumMacOS: s.minimumMacOS }];
  }
  return { all, nightly };
}

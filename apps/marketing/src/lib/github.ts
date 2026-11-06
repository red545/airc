import { GITHUB_REPO } from "./site";

// Stars are read once at build time (and cached for ten minutes in dev), never from the visitor's browser: the page
// makes no third-party requests. While the repo is private the API says 404, and the nav shows just the link.
let cache: { at: number; stars: number | null; isPublic: boolean } | undefined;

// Whether the repo can be opened by the public. While it's private, the page leaves out every GitHub link rather
// than send people to a 404.
export async function isPublic(): Promise<boolean> {
  await getStars();
  return cache?.isPublic ?? false;
}

export async function getStars(): Promise<number | null> {
  if (cache && Date.now() - cache.at < 10 * 60_000) return cache.stars;
  let stars: number | null = null;
  let open = false;
  try {
    const res = await fetch(`https://api.github.com/repos/${GITHUB_REPO}`, {
      headers: { Accept: "application/vnd.github+json", "User-Agent": "airc-homepage" },
      signal: AbortSignal.timeout(5000),
    });
    if (res.ok) {
      open = true;
      const n = ((await res.json()) as { stargazers_count?: unknown }).stargazers_count;
      if (typeof n === "number" && n > 0) stars = n;
    }
  } catch {
    // Offline or rate limited: show the link without a count.
  }
  cache = { at: Date.now(), stars, isPublic: open };
  return stars;
}

// 842 -> "842", 1234 -> "1.2K", 31400 -> "31K", 1_250_000 -> "1.3M"
export function compact(n: number): string {
  if (n < 1000) return String(n);
  const [v, unit] = n < 1_000_000 ? [n / 1000, "K"] : [n / 1_000_000, "M"];
  return `${v < 10 ? (Math.round(v * 10) / 10).toString() : Math.round(v)}${unit}`;
}

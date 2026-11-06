// /api/stars: whether the repo is public, and its star count, for the GitHub buttons' counts. The page asks this (first-party)
// instead of api.github.com, so visitors' browsers never talk to GitHub, and the CDN cache keeps GitHub's
// unauthenticated rate limit far away. The repo ("owner/name") is PUBLIC_GITHUB_REPO in the project's environment, as
// for the site's GitHub links (src/lib/site.ts).
declare const process: { env: Record<string, string | undefined> }; // Vercel's Node runtime

const REPO = process.env.PUBLIC_GITHUB_REPO ?? "";

export default async function handler(_req: unknown, res: any) {
  let body: { public: boolean; stars: number | null; url: string } = { public: false, stars: null, url: REPO ? `https://github.com/${REPO}` : "" };
  if (REPO) try {
    const r = await fetch(`https://api.github.com/repos/${REPO}`, {
      headers: { Accept: "application/vnd.github+json", "User-Agent": "aircbrowser.com" },
      signal: AbortSignal.timeout(3000),
    });
    if (r.ok) {
      const j = (await r.json()) as { private?: boolean; stargazers_count?: number; html_url?: string };
      if (!j.private) body = { public: true, stars: typeof j.stargazers_count === "number" ? j.stargazers_count : null, url: j.html_url ?? body.url };
    }
  } catch {
    // GitHub unreachable: say nothing changed; the cache below keeps the last good answer for a while.
  }
  res.setHeader("Cache-Control", "public, s-maxage=600, stale-while-revalidate=86400");
  res.setHeader("Content-Type", "application/json");
  res.status(200).send(JSON.stringify(body));
}

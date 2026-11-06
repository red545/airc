// /download (vercel.json rewrites it here): sends the latest stable DMG, and counts the download in PostHog first.
// No Blob credential belongs in this route.
declare const process: { env: Record<string, string | undefined> }; // Vercel's Node runtime

const base = "https://hpqylr02za4pig6a.public.blob.vercel-storage.com";

// The owner's PostHog EU project. Its key (public by design: capture-only, it ships inside the app) comes from the
// project's environment, PUBLIC_POSTHOG_KEY; without it downloads go uncounted.
const POSTHOG = "https://eu.i.posthog.com/i/v0/e/";
const POSTHOG_KEY = process.env.PUBLIC_POSTHOG_KEY ?? "";

type Req = { method?: string; headers: Record<string, string | string[] | undefined> };

const header = (req: Req, name: string) => {
  const v = req.headers[name];
  return Array.isArray(v) ? v[0] : v;
};

// The Referer's hostname only (never the full URL), or "direct".
const referrerHost = (req: Req) => {
  try {
    const r = header(req, "referer");
    return r ? new URL(r).hostname || "direct" : "direct";
  } catch {
    return "direct";
  }
};

// One anonymous event per download: a fresh random ID, no IP, no URL, no user agent, no cookies. It waits at most
// 300 ms; if PostHog is slow or down, the download goes ahead uncounted.
async function count(req: Req, version: string) {
  if (!POSTHOG_KEY) return;
  const country = header(req, "x-vercel-ip-country");
  try {
    await fetch(POSTHOG, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        api_key: POSTHOG_KEY,
        event: "site.download",
        distinct_id: crypto.randomUUID(),
        properties: {
          $process_person_profile: false,
          $geoip_disable: true,
          ...(country ? { country } : {}),
          referrer_host: referrerHost(req),
          version,
        },
      }),
      signal: AbortSignal.timeout(300),
    });
  } catch {
    // Not counted; the download still happens.
  }
}

export default async function handler(req: Req, res: any) {
  try {
    const response = await fetch(`${base}/feeds/latest.json`, { cache: "no-store" });
    if (!response.ok) throw new Error("No qualified stable release");
    const latest = await response.json();
    const url = new URL(latest.url);
    if (url.origin !== "https://aircbrowser.com" ||
        !/^\/releases\/\d+\.\d+\.\d+\/\d{12}\/Airc-[\d.]+\.dmg$/.test(url.pathname))
      throw new Error("Invalid release URL");
    // HEAD requests (link checkers, unfurlers) aren't downloads.
    if (req.method !== "HEAD") await count(req, String(latest.version));
    res.setHeader("Cache-Control", "no-store");
    res.redirect(307, `${base}${url.pathname}`);
  } catch {
    res.status(503).send("The download is not available yet. Please try again shortly.");
  }
}

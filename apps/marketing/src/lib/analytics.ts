// Site analytics: PostHog EU, the same project as the app. The project key (public by design: capture-only, it ships
// in the app) comes from the build environment, PUBLIC_POSTHOG_KEY, set in the Vercel project like the app's
// infra/release/telemetry.json; without it nothing is sent. What it records is listed on /privacy:
// - no cookies and no local storage: the random ID lives in memory and is gone when the tab closes;
// - no IP address kept and no location lookup ($geoip_disable, as in the app), no person profiles, no recordings;
// - Do Not Track is respected;
// - requests go to aircbrowser.com/ingest (vercel.json proxies it to PostHog EU), so it isn't a third-party call.
// Nothing is sent from the dev server or a local preview, only from the deployed site.
import type { PostHog } from "posthog-js";

const KEY: string = import.meta.env.PUBLIC_POSTHOG_KEY ?? "";

let ph: PostHog | undefined;
let started = false;
const queue: [string, Props, boolean][] = [];

// The library loads once the page is idle, so it never competes with the first paint. Events before that wait.
export function startAnalytics() {
  if (started || !KEY || !import.meta.env.PROD || !/(^|\.)aircbrowser\.com$/.test(location.hostname)) return;
  started = true;
  const load = async () => {
    const { default: posthog } = await import("posthog-js");
    init(posthog);
  };
  if ("requestIdleCallback" in window) requestIdleCallback(() => void load(), { timeout: 2500 });
  else setTimeout(() => void load(), 1200);
}

function init(posthog: PostHog) {
  posthog.init(KEY, {
    api_host: "/ingest",
    ui_host: "https://eu.posthog.com",
    persistence: "memory",
    person_profiles: "identified_only",
    autocapture: false,
    capture_pageview: true,
    capture_pageleave: true,
    disable_session_recording: true,
    disable_surveys: true,
    advanced_disable_flags: true,
    respect_dnt: true,
    property_denylist: ["$ip"],
  });
  posthog.register({ $geoip_disable: true });
  ph = posthog;
  for (const [e, p, l] of queue.splice(0)) send(e, p, l);
}

type Props = Record<string, string | number | boolean>;

const send = (event: string, props: Props, leaving: boolean) =>
  ph?.capture(event, props, leaving ? { transport: "sendBeacon" } : undefined);

// One named event. Leaving the page (a download, the release notes) goes by sendBeacon so it isn't lost.
export function track(event: string, props: Props = {}, leaving = false) {
  if (!started) return;
  if (ph) send(event, props, leaving);
  else if (queue.length < 50) queue.push([event, props, leaving]);
}

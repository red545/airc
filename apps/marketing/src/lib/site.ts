export const SITE_NAME = "Airc";
export const TAGLINE = "Built and maintained by AI";

// The waitlist is a plain email for now: no backend, no third-party form, no tracking.
export const CONTACT_EMAIL = "hello@aircbrowser.com";
export const WAITLIST_URL = `mailto:${CONTACT_EMAIL}?subject=${encodeURIComponent(
  "Airc waitlist",
)}&body=${encodeURIComponent("Please let me know when Airc is ready to download.")}`;

// Arc stops working on this day (The Browser Company's announcement). Midnight UTC is close enough for a countdown.
export const ARC_END = new Date("2026-12-22T00:00:00Z");

export function daysUntil(date: Date, from = new Date()): number {
  return Math.max(0, Math.ceil((date.getTime() - from.getTime()) / 86_400_000));
}

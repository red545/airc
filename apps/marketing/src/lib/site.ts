export const SITE_NAME = "Airc";
export const CONTACT_EMAIL = "hello@aircbrowser.com";

// Arc stops working on this day (The Browser Company's announcement, Oct 22, 2026). Midnight UTC is close enough for a countdown.
export const ARC_END = new Date("2026-12-22T00:00:00Z");

// The public repo ("owner/name"), from the build environment (PUBLIC_GITHUB_REPO, set in the Vercel project), so no
// account name sits in the source. Without it the site builds with no GitHub links.
export const GITHUB_REPO: string = import.meta.env.PUBLIC_GITHUB_REPO ?? "";
export const GITHUB_URL = GITHUB_REPO ? `https://github.com/${GITHUB_REPO}` : "";

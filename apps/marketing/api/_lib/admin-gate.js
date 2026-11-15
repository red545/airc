// The owner's admin pages (/admin/boosts, /admin/feedback) share one sign-in: HTTP Basic with any user name and
// SHARING_ADMIN_SECRET as the password (a Vercel environment variable, never in the repository). Without it set, the
// pages are closed (503). Failed sign-ins count against the visitor's rate limit.
import { problem, sameSecret } from "./http.js";
import { limit } from "./rate.js";
import { store } from "./store.js";

/** Whether the request carries the admin password. @param {Request} request @param {string} secret */
function signedIn(request, secret) {
  const m = /^Basic ([A-Za-z0-9+/=]+)$/.exec(request.headers.get("authorization") ?? "");
  if (!m) return false;
  const pair = Buffer.from(m[1], "base64").toString("utf8");
  const password = pair.slice(pair.indexOf(":") + 1);
  return sameSecret(password, secret);
}

const challenge = () =>
  new Response("Sign in with the gallery's admin password.", {
    status: 401,
    headers: { "WWW-Authenticate": 'Basic realm="Airc gallery", charset="UTF-8"', "Cache-Control": "no-store", "Content-Type": "text/plain" },
  });

/** Checks the password (and counts failures): null when signed in, else the answer. @param {Request} request
 *  @returns {Promise<Response | null>} */
export async function gate(request) {
  const secret = process.env.SHARING_ADMIN_SECRET;
  if (!secret || secret.length < 24) return problem(503, "closed", "The admin pages aren't set up (SHARING_ADMIN_SECRET).");
  if (signedIn(request, secret)) return null;
  if (request.headers.get("authorization")) {
    const limited = await limit(await store(), request, "admin");
    if (limited) return limited;
  }
  return challenge();
}

/** Whether a form post comes from the admin page itself (Origin), so another site can't trigger its actions.
 *  @param {Request} request */
export function sameOrigin(request) {
  const host = request.headers.get("host");
  const from = request.headers.get("origin");
  return !!from && !!host && URL.parse(from)?.host === host;
}

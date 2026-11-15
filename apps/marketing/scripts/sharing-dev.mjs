// The sharing functions (api/share.js, s.js, easel.js, e.js, boosts.js, admin.js, feedback.js) on a local port with the in-memory store, for
// Airc's sharing check (ParitySharingCheck) on a Mac without the Vercel CLI. Same handlers, same rewrites as
// vercel.json; nothing persists. `node scripts/sharing-dev.mjs [port]` (default 4390), on 127.0.0.1 only.
import { createServer } from "node:http";

process.env.SHARING_MEMORY_STORE = "1";
process.env.SHARING_ADMIN_SECRET ??= "local-admin-secret-for-checks-only";
const port = Number(process.argv[2] ?? 4390);

const routes = {
  "/api/share": await import("../api/share.js"),
  "/api/s": await import("../api/s.js"),
  "/api/easel": await import("../api/easel.js"),
  "/api/e": await import("../api/e.js"),
  "/api/boosts": await import("../api/boosts.js"),
  "/api/admin": await import("../api/admin.js"),
  "/api/feedback": await import("../api/feedback.js"),
  "/api/sweep": await import("../api/sweep.js"),
};

createServer(async (req, res) => {
  try {
    const url = new URL(req.url ?? "/", `http://${req.headers.host ?? `127.0.0.1:${port}`}`);
    // vercel.json's rewrites.
    const share = /^\/s\/([A-Za-z0-9]{12})$/.exec(url.pathname);
    let m;
    if (share) {
      url.pathname = "/api/s";
      url.searchParams.set("id", share[1]);
    } else if ((m = /^\/e\/([A-Za-z0-9]{12})(?:\/a\/([0-9a-f]{64}\.[a-z]{3,4}))?$/.exec(url.pathname))) {
      url.pathname = "/api/e";
      url.searchParams.set("id", m[1]);
      if (m[2]) url.searchParams.set("asset", m[2]);
    } else if (url.pathname === "/admin/boosts") url.pathname = "/api/admin";
    else if (url.pathname === "/admin/feedback") {
      url.pathname = "/api/feedback";
      url.searchParams.set("view", "admin");
    }
    const mod = routes[url.pathname];
    const handler = mod?.[req.method ?? "GET"];
    if (!handler) {
      res.writeHead(mod ? 405 : 404).end();
      return;
    }
    const chunks = [];
    for await (const c of req) chunks.push(c);
    const headers = new Headers();
    for (const [k, v] of Object.entries(req.headers)) if (typeof v === "string") headers.set(k, v);
    headers.set("x-real-ip", req.socket.remoteAddress ?? "127.0.0.1");
    const body = chunks.length && req.method !== "GET" && req.method !== "HEAD" ? Buffer.concat(chunks) : undefined;
    const response = await handler(new Request(url, { method: req.method, headers, body }));
    res.writeHead(response.status, Object.fromEntries(response.headers));
    res.end(Buffer.from(await response.arrayBuffer()));
    console.log(req.method, url.pathname + url.search, response.status);
  } catch (e) {
    console.error(e);
    res.writeHead(500).end();
  }
}).listen(port, "127.0.0.1", () => console.log(`sharing dev server on http://127.0.0.1:${port}`));

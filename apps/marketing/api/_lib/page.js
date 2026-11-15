// The HTML pages the sharing functions render (a shared Space or folder at /s/<id>, the admin queue): one card on the
// site's background, in the viewer's style (src/pages/s.astro). No scripts, fonts, pictures or requests from other
// sites; every string from a snapshot or a submission goes through esc().
import { createHash } from "node:crypto";
import { esc } from "./http.js";

const CSS = `
:root { --bg: #fcfbfa; --bg-sunk: #f6f4f2; --t1: rgb(20 17 15 / 0.92); --t2: rgb(20 17 15 / 0.68); --t3: rgb(20 17 15 / 0.48);
  --hl: #ececef; --hl-strong: #dedee3; --panel: #f8f8f9; --surface: #fff; --ink: 20 17 15; --red: #e5484d;
  --font: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Inter Variable", "Segoe UI", system-ui, sans-serif;
  --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace; color-scheme: light; }
* { box-sizing: border-box; }
html, body { min-height: 100%; }
body { margin: 0; font-family: var(--font); color: var(--t1); -webkit-font-smoothing: antialiased;
  background: radial-gradient(60% 50% at 15% 0%, rgb(83 202 159 / 0.22), transparent 70%),
    radial-gradient(50% 50% at 90% 10%, rgb(134 205 245 / 0.24), transparent 70%), #ebe8e4; }
a { color: inherit; text-decoration: none; }
.wrap { display: grid; justify-items: center; min-height: 100vh; padding: clamp(16px, 5vw, 56px) 16px; }
.card { width: min(100%, 720px); align-self: start; padding: clamp(24px, 5vw, 44px); border-radius: 18px; background: var(--bg);
  box-shadow: 0 0 0 0.5px rgb(var(--ink) / 0.1), 0 24px 60px -24px rgb(30 25 20 / 0.35); }
.card.wide { width: min(100%, 1040px); }
.mark { display: block; width: fit-content; margin-bottom: 18px; }
.mark img { display: block; width: 40px; height: 40px; }
.tag { display: inline-flex; align-items: center; height: 24px; margin: 0 0 12px; padding: 0 9px; border-radius: 7px;
  font-size: 12.5px; font-weight: 600; color: #2a6fd1; background: rgb(58 114 222 / 0.1); }
.tag.gone { color: var(--t2); background: rgb(var(--ink) / 0.06); }
h1 { margin: 0; font-size: clamp(26px, 4vw, 34px); line-height: 1.12; font-weight: 560; letter-spacing: -0.024em;
  overflow-wrap: anywhere; text-wrap: balance; }
h1 span { color: var(--t3); }
h2 { margin: 32px 0 8px; font-size: 18px; font-weight: 600; }
.lede { margin: 14px 0 0; font-size: 15.5px; line-height: 1.6; color: var(--t2); overflow-wrap: anywhere; }
.actions { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin: 22px 0 0; }
.btn-open { display: inline-flex; align-items: center; height: 42px; padding: 0 16px; border: 0; border-radius: 12px;
  font: inherit; font-size: 15px; font-weight: 600; color: #fff; background: #18181b; box-shadow: 0 1px 2px rgb(0 0 0 / 0.2); cursor: pointer; }
.btn-open:hover { background: #2a2a2e; }
.btn-quiet { display: inline-flex; align-items: center; height: 42px; padding: 0 14px; border: 0; border-radius: 12px;
  font: inherit; font-size: 14.5px; font-weight: 550; color: var(--t1); background: var(--surface);
  box-shadow: inset 0 0 0 1px var(--hl-strong); cursor: pointer; }
.btn-quiet:hover { box-shadow: inset 0 0 0 1px var(--t3); }
.btn-quiet.danger { color: var(--red); }
.snap { margin: 16px 0 0; font-size: 13px; line-height: 1.55; color: var(--t3); }
.tree { margin: 24px 0 0; padding: 0; list-style: none; box-shadow: 0 -1px 0 var(--hl); }
.tree ul { margin: 0 0 0 9px; padding: 0 0 0 14px; list-style: none; box-shadow: inset 1px 0 0 var(--hl); }
.tree li { margin: 0; }
.tree .t { display: flex; align-items: center; gap: 10px; min-height: 40px; padding: 0 8px; border-radius: 9px; font-size: 14.5px; font-weight: 500; }
.tree .t:hover { background: var(--panel); }
.t-mark { display: grid; place-items: center; flex: none; width: 20px; height: 20px; border-radius: 6px; font-size: 11px;
  font-weight: 650; color: var(--t2); background: rgb(var(--ink) / 0.06); }
.t-title { flex: 1 1 auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.t-host { flex: none; max-width: 40%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 12.5px; color: var(--t3); }
.f-name { display: flex; align-items: center; gap: 10px; min-height: 40px; padding: 0 8px; font-size: 14.5px; font-weight: 600; overflow-wrap: anywhere; }
.f-name::before { content: ""; flex: none; width: 20px; height: 16px; border-radius: 3px 4px 4px 4px;
  background: linear-gradient(#7aa5f0, #7aa5f0) 0 0 / 9px 4px no-repeat, linear-gradient(#8fb3f3, #6d97ea) 0 3px / 20px 13px no-repeat; }
.empty { padding: 8px 8px 10px; font-size: 13px; color: var(--t3); }
.split { padding: 6px 0; }
.s-label { display: block; padding: 0 8px 4px; font-size: 11.5px; font-weight: 600; letter-spacing: 0.02em; text-transform: uppercase; color: var(--t3); }
.s-row { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 4px; padding: 4px; border-radius: 11px; box-shadow: inset 0 0 0 1px var(--hl); }
.split.vertical .s-row { grid-template-columns: 1fr; }
.s-row .t { background: var(--bg-sunk); }
.foot { margin: 28px 0 0; padding-top: 18px; font-size: 13px; color: var(--t3); box-shadow: 0 -1px 0 var(--hl); }
.foot a { color: var(--t2); text-decoration: underline; text-decoration-color: var(--hl-strong); text-underline-offset: 3px; }
.item { margin: 16px 0 0; padding: 18px; border-radius: 14px; background: var(--surface); box-shadow: inset 0 0 0 1px var(--hl-strong); }
.item h3 { margin: 0; font-size: 16px; }
.item .meta { margin: 4px 0 0; font-size: 13px; color: var(--t3); overflow-wrap: anywhere; }
.item .notes { margin: 10px 0 0; padding: 8px 12px; border-radius: 9px; font-size: 13px; color: #8a5a00; background: rgb(255 180 0 / 0.12); }
.item pre { margin: 10px 0 0; padding: 12px; max-height: 420px; overflow: auto; border-radius: 9px; font: 12px/1.5 var(--mono);
  white-space: pre-wrap; overflow-wrap: anywhere; background: var(--bg-sunk); }
.item img { display: block; max-width: 100%; max-height: 260px; margin: 10px 0 0; border-radius: 9px; box-shadow: 0 0 0 1px var(--hl); }
.item form { display: contents; }
.item .actions { margin-top: 14px; }
@media (max-width: 520px) { .t-host { display: none; } .actions > * { flex: 1 1 auto; justify-content: center; } }
`;

/** A script's CSP hash. @param {string} code */
export const scriptHash = (code) => `'sha256-${createHash("sha256").update(code).digest("base64")}'`;

/**
 * A whole page. `script` is inline code allowed by its hash; nothing else runs.
 * @param {{ title: string, body: string, status?: number, script?: string, wide?: boolean, headers?: Record<string, string>,
 *   images?: boolean, css?: string }} p
 */
export function page({ title, body, status = 200, script, wide, headers = {}, images, css = "" }) {
  const csp = [
    "default-src 'none'",
    "style-src 'unsafe-inline'",
    `img-src 'self'${images ? " data:" : ""}`,
    "form-action 'self'",
    "base-uri 'none'",
    "frame-ancestors 'none'",
    ...(script ? [`script-src ${scriptHash(script)}`] : []),
  ].join("; ");
  const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light only">
<meta name="robots" content="noindex">
<meta name="referrer" content="no-referrer">
<title>${esc(title)}</title>
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<style>${CSS}${css}</style>
</head>
<body>
<main class="wrap"><article class="card${wide ? " wide" : ""}">
<a class="mark" href="/" aria-label="Airc"><img src="/apple-touch-icon.png" alt="" width="40" height="40"></a>
${body}
</article></main>
${script ? `<script>${script}</script>` : ""}
</body>
</html>`;
  return new Response(html, {
    status,
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Content-Security-Policy": csp,
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
      "X-Robots-Tag": "noindex",
      "Cache-Control": "no-store",
      ...headers,
    },
  });
}

export { esc };

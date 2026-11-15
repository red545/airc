// Reads a share link's fragment (`v1.<payload>`, docs/dev/share-links.md) the way Airc does (AircKit ShareLink), all or
// nothing, in the browser. It never sends anything anywhere: it's used only by /s, which runs no analytics. The schema
// and limits are in share-core.js, which the sharing functions (api/) use too.
import { decodeSnapshot, fail, MAX_JSON, MAX_PAYLOAD, Refused, VERSION } from "./share-core.js";

export { addresses, hostOf, isSafeAddress, messages } from "./share-core.js";

export type Failure = "damaged" | "newerVersion" | "tooLarge" | "unsafeAddress" | "unsupported";
export type Tab = { type: "tab"; url: string; title?: string };
export type Node = Tab | { type: "folder"; name: string; items: Node[] } | { type: "split"; axis: "horizontal" | "vertical"; items: Tab[] };
export type Snapshot =
  | { kind: "space" | "folder"; name: string; icon?: string; items: Node[]; tabs: number; folders: number }
  | { kind: "boost"; name: string; site: string; author?: string; about?: string; code: boolean };

function unbase64url(s: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(s) || s.length % 4 === 1) fail("damaged");
  let b = s.replace(/-/g, "+").replace(/_/g, "/");
  while (b.length % 4) b += "=";
  try {
    const bin = atob(b);
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch {
    return fail("damaged");
  }
}

/** Raw DEFLATE, stopped as soon as it passes the cap (a "zip bomb" isn't inflated any further). */
async function inflate(bytes: Uint8Array): Promise<Uint8Array> {
  if (typeof DecompressionStream === "undefined") fail("unsupported");
  let stream: ReadableStream<Uint8Array>;
  try {
    stream = new Blob([bytes as BlobPart]).stream().pipeThrough(new DecompressionStream("deflate-raw" as CompressionFormat));
  } catch {
    return fail("unsupported");
  }
  const reader = stream.getReader();
  const parts: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    let r: ReadableStreamReadResult<Uint8Array>;
    try {
      r = await reader.read();
    } catch {
      return fail("damaged");
    }
    if (r.done) break;
    total += r.value.length;
    if (total > MAX_JSON) {
      reader.cancel().catch(() => {});
      return fail("tooLarge");
    }
    parts.push(r.value);
  }
  const out = new Uint8Array(total);
  let at = 0;
  for (const p of parts) {
    out.set(p, at);
    at += p.length;
  }
  return out;
}

/** The snapshot in `fragment` (location.hash without the "#"), or why it's refused. */
export async function read(fragment: string): Promise<{ ok: true; snapshot: Snapshot } | { ok: false; why: Failure }> {
  try {
    const m = /^v([^.]*)\.(.*)$/s.exec(fragment);
    if (!m || !/^[1-9]\d{0,8}$/.test(m[1])) fail("damaged");
    const v = Number(m![1]);
    if (v !== VERSION) fail(v > VERSION ? "newerVersion" : "damaged");
    const payload = m![2];
    if (payload.length > MAX_PAYLOAD) fail("tooLarge");
    if (!payload) fail("damaged");
    const bytes = await inflate(unbase64url(payload));
    let json: string;
    try {
      json = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    } catch {
      return { ok: false, why: "damaged" };
    }
    return { ok: true, snapshot: decodeSnapshot(json) as Snapshot };
  } catch (e) {
    if (e instanceof Refused) return { ok: false, why: e.why };
    return { ok: false, why: "damaged" };
  }
}

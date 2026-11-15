import { blobCall, Unavailable } from "./blob-retry.js";
export { Unavailable } from "./blob-retry.js";
// Where sharing keeps its few records (docs/dev/sharing-service.md): a private Vercel Blob store of its own
// ("airc-sharing", separate from the releases store), reached with SHARING_READ_WRITE_TOKEN. Nothing in it is
// public: every read goes through these functions. The API tests and the local dev server use the in-memory store
// instead (SHARING_MEMORY_STORE=1); without either, sharing answers 503.

/** @typedef {{ text: string, etag: string }} Record */
/** @typedef {{ key: string, uploadedAt: Date }} Listed */
/** @typedef {{ ifMatch?: string, overwrite?: boolean, contentType?: string }} PutOptions */
/**
 * @typedef {object} Store
 * @property {(key: string) => Promise<Record | null>} get
 * @property {(key: string) => Promise<{ bytes: Uint8Array, contentType: string } | null>} getBytes
 * @property {(key: string, body: string | Uint8Array, options?: PutOptions) => Promise<string>} put
 *   Writes `body`. By default only a new key ("create"); `overwrite` replaces; `ifMatch` replaces only that version.
 *   Throws Conflict when the key exists (create) or changed (ifMatch).
 * @property {(keys: string | string[]) => Promise<void>} del
 * @property {(prefix: string) => Promise<Listed[]>} list
 */

export class Conflict extends Error {}


/** @type {Store | null} */
let cached = null;

/** The store for this deployment. @returns {Promise<Store>} */
export async function store() {
  if (cached) return cached;
  const token = process.env.SHARING_READ_WRITE_TOKEN;
  // One store serves every environment: Previews and `vercel dev` keep their records under their own prefix, so
  // nothing they create (or approve) ever reaches aircbrowser.com.
  const env = process.env.VERCEL_ENV;
  if (token) cached = prefixed(await blobStore(token), env === "production" ? "" : `${env || "development"}/`);
  else if (process.env.SHARING_MEMORY_STORE === "1") cached = memoryStore();
  else throw new Unavailable("no sharing store configured");
  return cached;
}

/** For the tests: a fresh in-memory store. */
export function resetMemoryStore() {
  cached = memoryStore();
  return cached;
}

/** `s` with every key under `prefix`. @param {Store} s @param {string} prefix @returns {Store} */
export function prefixed(s, prefix) {
  if (!prefix) return s;
  /** @param {string} k */
  const p = (k) => prefix + k;
  return {
    get: (k) => s.get(p(k)),
    getBytes: (k) => s.getBytes(p(k)),
    put: (k, body, o) => s.put(p(k), body, o),
    del: (keys) => s.del([keys].flat().map(p)),
    list: async (prefix2) => (await s.list(p(prefix2))).map((b) => ({ ...b, key: b.key.slice(prefix.length) })),
  };
}

/** @returns {Store} */
export function memoryStore() {
  /** @type {Map<string, { body: Uint8Array, etag: string, contentType: string, at: Date }>} */
  const m = new Map();
  let n = 0;
  const enc = new TextEncoder(), dec = new TextDecoder();
  return {
    async get(key) {
      const r = m.get(key);
      return r ? { text: dec.decode(r.body), etag: r.etag } : null;
    },
    async getBytes(key) {
      const r = m.get(key);
      return r ? { bytes: r.body, contentType: r.contentType } : null;
    },
    async put(key, body, o = {}) {
      const old = m.get(key);
      if (o.ifMatch !== undefined ? old?.etag !== o.ifMatch : old && !o.overwrite) throw new Conflict(key);
      const etag = `"m${++n}"`;
      m.set(key, {
        body: typeof body === "string" ? enc.encode(body) : body,
        etag,
        contentType: o.contentType ?? "application/json",
        at: new Date(),
      });
      return etag;
    },
    async del(keys) {
      for (const k of [keys].flat()) m.delete(k);
    },
    async list(prefix) {
      return [...m.entries()].filter(([k]) => k.startsWith(prefix)).map(([key, r]) => ({ key, uploadedAt: r.at }));
    },
  };
}

/** @param {string} token @param {typeof import("@vercel/blob")} [blob] @returns {Promise<Store>} */
export async function blobStore(token, blob = undefined) {
  // SDK 2.8.2 defaults to ten hidden retries. In particular, a lost CAS response must
  // never become a Conflict that update()/limit() interpret as permission to increment again.
  process.env.VERCEL_BLOB_RETRIES = "0";
  blob ??= await import("@vercel/blob");
  const base = { token, access: /** @type {const} */ ("private") };
  /** @param {unknown} e */
  const isConflict = (e) =>
    e instanceof blob.BlobPreconditionFailedError || (e instanceof Error && /already exists|precondition/i.test(e.message));
  /** @param {string} key */
  const read = (key) => blobCall(async (abortSignal) => {
    try {
      const r = await blob.get(key, { ...base, useCache: false, abortSignal });
      if (!r) return null;
      if (r.statusCode !== 200) throw new Error("Unexpected Blob read status");
      const bytes = new Uint8Array(await new Response(r.stream).arrayBuffer());
      // A compressed answer carries a weak ETag (W/"…"); conditional writes take the strong form of the same tag.
      return { bytes, etag: r.blob.etag.replace(/^W\//, ""), contentType: r.blob.contentType };
    } catch (e) {
      if (e instanceof blob.BlobNotFoundError) return null;
      throw e;
    }
  });
  return {
    async get(key) {
      const r = await read(key);
      return r ? { text: new TextDecoder().decode(r.bytes), etag: r.etag } : null;
    },
    async getBytes(key) {
      const r = await read(key);
      return r ? { bytes: r.bytes, contentType: r.contentType } : null;
    },
    async put(key, body, o = {}) {
      try {
        const r = await blobCall((abortSignal) => blob.put(key, typeof body === "string" ? body : Buffer.from(body), {
          ...base,
          abortSignal,
          addRandomSuffix: false,
          contentType: o.contentType ?? "application/json",
          cacheControlMaxAge: 60,
          ...(o.ifMatch !== undefined ? { ifMatch: o.ifMatch } : { allowOverwrite: !!o.overwrite }),
        }), { retry: o.overwrite === true && o.ifMatch === undefined });
        return r.etag;
      } catch (e) {
        if (isConflict(e)) throw new Conflict(key);
        throw e;
      }
    },
    async del(keys) {
      const list = [keys].flat();
      if (list.length) await blobCall((abortSignal) => blob.del(list, { token, abortSignal }));
    },
    async list(prefix) {
      /** @type {Listed[]} */
      const out = [];
      /** @type {string | undefined} */
      let cursor;
      do {
        const r = await blobCall((abortSignal) => blob.list({ token, prefix, cursor, limit: 1000, abortSignal }));
        out.push(...r.blobs.map((b) => ({ key: b.pathname, uploadedAt: new Date(b.uploadedAt) })));
        cursor = r.hasMore ? r.cursor : undefined;
      } while (cursor);
      return out;
    },
  };
}

/** Reads a JSON record, or null. @param {Store} s @param {string} key */
export async function getJSON(s, key) {
  const r = await s.get(key);
  if (!r) return null;
  return { value: JSON.parse(r.text), etag: r.etag };
}

/** Changes a JSON record with `change(old)` until no one else changed it in between (a few tries).
 *  @template T @param {Store} s @param {string} key @param {(old: T | null) => T} change @param {T} [fallback] */
export async function update(s, key, change, fallback) {
  for (let i = 0; i < 5; i++) {
    const r = await getJSON(s, key);
    const next = change(r ? r.value : fallback ?? null);
    try {
      await s.put(key, JSON.stringify(next), r ? { ifMatch: r.etag } : {});
      return next;
    } catch (e) {
      if (!(e instanceof Conflict)) throw e;
    }
  }
  throw new Conflict(key);
}

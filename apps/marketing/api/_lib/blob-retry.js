// One budget includes SDK requests, body consumption and backoff. Never wrap a
// read/modify/write transaction: an ambiguous write must not increment it again.
export class Unavailable extends Error {}

/** Only known transient failures qualify; a generic BlobError can also mean a bad request.
 * @param {any} error */
export function transient(error) {
  const status = Number(error?.status ?? error?.statusCode ??
    /Failed to fetch blob: (\d{3})\b/.exec(error?.message ?? "")?.[1]);
  if (status) return status === 429 || (status >= 500 && status <= 599);
  return ["BlobServiceNotAvailable", "BlobServiceRateLimited"].includes(error?.constructor?.name) ||
    /^(ECONNRESET|ECONNREFUSED|ETIMEDOUT|EAI_AGAIN|ENETUNREACH|UND_ERR_.*)$/.test(error?.code ?? error?.cause?.code ?? "") ||
    (error instanceof TypeError && /fetch failed|network|terminated/i.test(error.message));
}

/** @template T @param {(signal: AbortSignal) => Promise<T>} operation
 * @param {{ retry?: boolean, budgetMs?: number, sleep?: (ms: number) => Promise<void>, random?: () => number }} [options]
 * @returns {Promise<T>} */
export async function blobCall(operation, { retry = true, budgetMs = 1500,
  sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)), random = Math.random } = {}) {
  const controller = new AbortController();
  const deadline = Date.now() + budgetMs;
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(new Unavailable("storage deadline exceeded"));
    }, budgetMs);
  });
  try {
    for (let attempt = 0; ; attempt++) {
      try {
        // Promise.race observes late rejections too, including after an abort.
        return await Promise.race([operation(controller.signal), timeout]);
      } catch (error) {
        if (error instanceof Unavailable) throw error;
        // Definite CAS/create conflicts remain available to the caller's concurrency loop.
        if (/precondition|already exists/i.test(error instanceof Error ? error.message : "")) throw error;
        if (!retry || !transient(error) || attempt === 2) throw new Unavailable("storage request failed");
        const delay = 50 * 2 ** attempt * (1 + random());
        // Respect long rate-limit advice by returning 503 instead of retrying early.
        const advised = Number(/** @type {any} */ (error)?.retryAfter ?? 0) * 1000;
        const wait = Math.max(delay, advised);
        if (Date.now() + wait >= deadline) throw new Unavailable("storage retry budget exhausted");
        await Promise.race([sleep(wait), timeout]);
      }
    }
  } finally {
    clearTimeout(timer);
  }
}

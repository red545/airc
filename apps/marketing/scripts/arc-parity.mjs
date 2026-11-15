#!/usr/bin/env node
// Builds src/data/arc-parity.json, the data of /arc ("Every Arc feature, and where it is in Airc"), from the parity
// ledger. Run it after each release or parity refresh, check the warnings, and commit the result:
//
//   node apps/marketing/scripts/arc-parity.mjs [--check] [--verbose]
//
// - Rows and their status come from docs/qa/parity-audit.md's Feature inventory (docs/qa/arc-parity.md is the older
//   requirement checklist; the audit is the full ledger it points to). done → Works, partial → Partly,
//   missing → Not yet, out of scope → Won't do. Owner-gated rows wait on a by-hand check, so their public status
//   (works or partly) is chosen in the copy file.
// - The words come from scripts/arc-parity-copy.json, one entry per ledger row: the feature in Arc's words, where it
//   is in Airc, an honest note and the first release with it. A ledger row without an entry, or an entry without a
//   row, stops the script, so a new row can't go public without its words.
// - "since" is checked against the commits a row cites: with --verbose, a version earlier than the first release
//   containing any of them is listed (often the ledger cites a later fix; check the row's first release by hand). Releases are read from src/content/changelog (each entry's Source commit).
// - The page itself (src/pages/arc.astro) shows a row as released only once its version is published; until then
//   it says "Coming in the next update".
// The output has no ledger IDs, paths or check names: it's public.
// --check: build in memory and fail if the committed file differs (for CI or a release step).

import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const site = resolve(here, "..");
const repo = resolve(site, "../..");
const out = join(site, "src/data/arc-parity.json");
const check = process.argv.includes("--check");
const verbose = process.argv.includes("--verbose");

const fail = (msg) => {
  console.error(`arc-parity: ${msg}`);
  process.exit(1);
};
const warnings = [];
const early = [];

// --- The ledger ------------------------------------------------------------------------------------------------
const ledger = readFileSync(join(repo, "docs/qa/parity-audit.md"), "utf8");
const checked = ledger.match(/^## (\d{4}-\d{2}-\d{2}) refresh$/m)?.[1];
if (!checked) fail("no '## YYYY-MM-DD refresh' heading in parity-audit.md");
const inventory = ledger.split(/^## Feature inventory$/m)[1]?.split(/^## /m)[0];
if (!inventory) fail("no '## Feature inventory' section in parity-audit.md");

const STATUS = { done: "works", partial: "partly", missing: "not-yet", "out of scope": "wont", "owner-gated": null };
const rows = [];
for (const line of inventory.split("\n")) {
  const m = line.match(/^\| ([A-Z]\d{2}) · ([^|]+)\|/);
  if (!m) continue;
  const cells = line.replace(/^\||\|$/g, "").split("|").map((c) => c.trim());
  const [, , status, evidence = "", missing = ""] = cells;
  if (!(status in STATUS)) fail(`${m[1]}: unknown status "${status}"`);
  rows.push({ id: m[1], feature: m[2].trim(), status, evidence, missing });
}
if (rows.length < 100) fail(`only ${rows.length} inventory rows parsed; has the table changed shape?`);

// --- Releases --------------------------------------------------------------------------------------------------
const cmp = (a, b) => {
  const x = a.split(".").map(Number), y = b.split(".").map(Number);
  return x[0] - y[0] || x[1] - y[1] || x[2] - y[2];
};
const changelog = join(site, "src/content/changelog");
const releases = readdirSync(changelog)
  .map((f) => f.match(/^(\d+\.\d+\.\d+)\.md$/)?.[1])
  .filter(Boolean)
  .map((version) => {
    const src = readFileSync(join(changelog, `${version}.md`), "utf8").match(/^Source: `([0-9a-f]{7,40})`/m)?.[1];
    return { version, src };
  })
  .filter((r) => r.src)
  .sort((a, b) => cmp(a.version, b.version));
const versions = new Set(releases.map((r) => r.version));

const git = (...args) => {
  try {
    execFileSync("git", ["-C", repo, ...args], { stdio: "ignore" });
    return true;
  } catch {
    return false;
  }
};
const haveSources = releases.every((r) => git("cat-file", "-e", `${r.src}^{commit}`));
if (!haveSources) warnings.push("some release source commits are missing locally (shallow clone?): since cross-check skipped");
const firstRelease = new Map();
/** The first release whose source contains `hash`, "next" if none does, undefined if the hash isn't a commit here. */
const releaseOf = (hash) => {
  if (firstRelease.has(hash)) return firstRelease.get(hash);
  let v;
  if (git("cat-file", "-e", `${hash}^{commit}`)) {
    v = releases.find((r) => git("merge-base", "--is-ancestor", hash, r.src))?.version ?? "next";
  }
  firstRelease.set(hash, v);
  return v;
};

// --- The words -------------------------------------------------------------------------------------------------
const copy = JSON.parse(readFileSync(join(here, "arc-parity-copy.json"), "utf8"));
const areaIds = new Set(copy.areas.map((a) => a.id));
const ids = new Set(rows.map((r) => r.id));
for (const id of Object.keys(copy.rows)) if (!ids.has(id)) fail(`copy has ${id}, which the ledger no longer lists`);

const slug = (s) =>
  s
    .toLowerCase()
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .replace(/⌘/g, "cmd")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .split("-")
    .slice(0, 8)
    .join("-");
// Nothing internal on a public page.
const PRIVATE = /\b[A-Z]{1,3}-?\d{1,2}[a-z]?\b|\b[0-9a-f]{7,40}\b|\/home\/|artifacts\/|docs\/qa|C:|--script|owner|agent[s]? (?:run|check)/;

const byArea = new Map(copy.areas.map((a) => [a.id, []]));
const missingCopy = [];
for (const r of rows) {
  const c = copy.rows[r.id];
  if (!c) {
    missingCopy.push(`${r.id} (${r.feature}, ${r.status})`);
    continue;
  }
  if (!areaIds.has(c.area)) fail(`${r.id}: unknown area "${c.area}"`);
  let status = STATUS[r.status];
  if (r.status === "owner-gated") {
    if (!["works", "partly"].includes(c.status)) fail(`${r.id} is owner-gated: its copy needs "status": "works" or "partly"`);
    status = c.status;
  } else if (c.status) fail(`${r.id}: "status" in the copy is only for owner-gated rows (the ledger says ${r.status})`);
  if (["partly", "wont", "not-yet"].includes(status) && !c.note) fail(`${r.id}: a ${status} row needs a note`);
  if (status === "wont") {
    if (c.since) fail(`${r.id}: a Won't do row has no since`);
  } else {
    if (!c.since) fail(`${r.id}: needs "since" (a released version, or "next")`);
    if (c.since !== "next" && !versions.has(c.since)) fail(`${r.id}: since ${c.since} isn't a release in src/content/changelog`);
    if (haveSources) {
      const cited = [...new Set(r.evidence.match(/(?<![0-9A-Za-z/])[0-9a-f]{7,40}(?![0-9A-Za-z])/g) ?? [])].filter((h) => /[a-f]/.test(h));
      const found = cited.map(releaseOf).filter(Boolean);
      const earliest = found.sort((a, b) => (a === "next" ? 1 : b === "next" ? -1 : cmp(a, b)))[0];
      if (earliest && c.since !== "next" && (earliest === "next" || cmp(c.since, earliest) < 0)) {
        early.push(`${r.id}: since ${c.since}, but the earliest commit it cites is first in ${earliest}`);
      }
    }
  }
  for (const [k, v] of Object.entries({ arc: c.arc, where: c.where, note: c.note ?? "" })) {
    if (PRIVATE.test(v)) fail(`${r.id}: its ${k} looks internal: "${v}"`);
  }
  byArea.get(c.area).push({ slug: slug(c.arc), arc: c.arc, status, where: c.where, note: c.note ?? "", since: c.since ?? null });
}
if (missingCopy.length) fail(`ledger rows without public words in arc-parity-copy.json:\n  ${missingCopy.join("\n  ")}`);

const seen = new Set();
for (const list of byArea.values())
  for (const row of list) {
    let s = row.slug, n = 2;
    while (seen.has(s)) s = `${row.slug}-${n++}`;
    seen.add(s);
    row.slug = s;
  }

const counts = {};
for (const r of rows) counts[r.status] = (counts[r.status] ?? 0) + 1;
const data = {
  _generated: "by apps/marketing/scripts/arc-parity.mjs from docs/qa/parity-audit.md and scripts/arc-parity-copy.json; don't edit by hand",
  checked,
  ledger: counts,
  areas: copy.areas.map((a) => ({ id: a.id, name: a.name, rows: byArea.get(a.id) })).filter((a) => a.rows.length),
};
const text = JSON.stringify(data, null, 2) + "\n";

for (const w of warnings) console.warn(`arc-parity: warning: ${w}`);
if (verbose) for (const e of early) console.warn(`arc-parity: earlier than its cited commits: ${e}`);
else if (early.length) console.warn(`arc-parity: ${early.length} rows date earlier than the commits they cite (--verbose lists them)`);
if (check) {
  let old = "";
  try {
    old = readFileSync(out, "utf8");
  } catch {}
  if (old !== text) fail("src/data/arc-parity.json is out of date: run node apps/marketing/scripts/arc-parity.mjs");
  console.log(`arc-parity: up to date (${rows.length} rows, checked ${checked})`);
} else {
  writeFileSync(out + ".tmp", text);
  (await import("node:fs")).renameSync(out + ".tmp", out);
  console.log(`arc-parity: wrote ${out.slice(repo.length + 1)}: ${rows.length} rows (${Object.entries(counts).map(([k, v]) => `${v} ${k}`).join(", ")}), checked ${checked}`);
}

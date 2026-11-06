// Refreshes what the page says Airc can do from the nightly runs. (Screenshots come from assets/screenshots, made by
// scripts/marketing-shots.sh, and are copied in by scripts/sync-screenshots.mjs.)
//
//   AIRC_STATUS_DIR=<dir that holds runs/> node scripts/sync-status.mjs
//   node scripts/sync-status.mjs --run <one run's dir>
//
// A run is the nightly's output: <run>/snapshots/chromium/log.txt (one PASS / FAIL / SKIP line per real-event check
// on the real Chromium engine), the captures beside it, rev.txt and steps.tsv. A run is green when its Chromium log has
// no FAIL line and its build-app step succeeded. Some green runs only run a subset of the scenarios, so each feature
// takes its result from the newest green run (of the last 12) that ran a check for it. It writes:
//
//   src/data/status.json          per feature: passing / failing / built (no nightly check yet), with check counts
//
// src/data/features.json says which log lines belong to which feature. Both outputs are committed, so the site
// builds anywhere (Vercel has no run directory); the nightly calls this after every run (infra/nightly.sh).
import { existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";


const here = new URL(".", import.meta.url).pathname;
const args = process.argv.slice(2);
const runArg = args.includes("--run") ? args[args.indexOf("--run") + 1] : undefined;
const statusDir = process.env.AIRC_STATUS_DIR;

const read = (p) => (existsSync(p) ? readFileSync(p, "utf8") : "");
const lines = (run) => read(join(run, "snapshots/chromium/log.txt")).split("\n");
const hasFail = (run) => lines(run).some((l) => /^(FAIL|ENGINE-FAIL) /.test(l));
const buildOk = (run) => /^build-app\t0\t/m.test(read(join(run, "steps.tsv")));

function greenRuns() {
  if (runArg) return [resolve(runArg)];
  if (!statusDir) {
    console.error("Set AIRC_STATUS_DIR (the folder that holds runs/), or pass --run <dir>.");
    process.exit(1);
  }
  const runs = join(statusDir, "runs");
  const green = readdirSync(runs)
    .sort()
    .reverse()
    .map((n) => join(runs, n))
    .filter((run) => existsSync(join(run, "snapshots/chromium/log.txt")) && buildOk(run) && !hasFail(run))
    .slice(0, 12);
  if (!green.length) {
    console.error("No green run with Chromium results found.");
    process.exit(1);
  }
  return green;
}

// Every check line: "PASS new space: typed "Nope"" -> { result, text }.
const checksOf = (run) =>
  lines(run).flatMap((l) => {
    const m = l.match(/^(PASS|FAIL|SKIP|ENGINE-PASS|ENGINE-FAIL) (.*)$/);
    if (!m) return [];
    return [{ result: m[1].endsWith("PASS") ? "pass" : m[1].endsWith("FAIL") ? "fail" : "skip", text: m[2].toLowerCase() }];
  });

const runs = greenRuns();
const stampOf = (run) => run.split("/").filter(Boolean).pop(); // 2026-11-06_0705
const isoOf = (run) => {
  const [date, time] = stampOf(run).split("_");
  return `${date}T${time.slice(0, 2)}:${time.slice(2)}:00Z`;
};
const run = runs[0];
const checks = checksOf(run);

const features = JSON.parse(read(join(here, "../src/data/features.json")));
const out = {};
const runChecks = runs.map((r) => ({ run: r, checks: r === run ? checks : checksOf(r) }));
for (const f of features) {
  const res = f.checks.map((c) => new RegExp(c));
  const match = (c) => res.some((r) => r.test(c.text));
  // The newest green run that ran a check for this feature.
  const hit = res.length ? runChecks.find((rc) => rc.checks.some(match)) : undefined;
  const mine = hit ? hit.checks.filter(match) : [];
  const n = (r) => mine.filter((c) => c.result === r).length;
  const [pass, fail, skip] = [n("pass"), n("fail"), n("skip")];
  out[f.id] = {
    status: fail ? "failing" : pass ? "passing" : "built",
    pass,
    skip,
    fail,
    ...(hit && hit.run !== run ? { checkedAt: isoOf(hit.run) } : {}),
  };
}

const total = (r) => checks.filter((c) => c.result === r).length;
const data = {
  checkedAt: isoOf(run),
  rev: read(join(run, "rev.txt")).trim(),
  chromium: read(resolve(here, "../../../CHROMIUM_VERSION")).trim(),
  checks: { pass: total("pass"), skip: total("skip"), fail: total("fail") },
  features: out,
};
writeFileSync(join(here, "../src/data/status.json"), JSON.stringify(data, null, 2) + "\n");


const counts = Object.values(out).reduce((a, f) => ((a[f.status] = (a[f.status] ?? 0) + 1), a), {});
console.log(`${stampOf(run)} @ ${data.rev}: ${data.checks.pass} checks passing, features`, counts);

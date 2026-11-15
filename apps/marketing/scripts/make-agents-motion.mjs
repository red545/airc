// The homepage's "For AI agents" loop: frames from a scripted run of the real app (`--script agentspike --agent-demo`,
// apps/browser/Sources/Airc/Debug/AgentsDemo.swift: an MCP client named Claude orders from a synthetic bakery site in
// an agent window, the person already signed in there) into the animated WebP the section plays, plus its last frame
// as the reduced-motion still. Each frame keeps its own timing from capture.json. Output: public/motion/agents.webp and
// agents-still.webp, served as is. Re-run after the demo re-renders, and commit both.
//   node scripts/make-agents-motion.mjs <frames dir>   (the run's agents-demo/ folder)
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
const sharp = createRequire(import.meta.url)("sharp");

const dir = process.argv[2];
if (!dir) throw new Error("usage: node scripts/make-agents-motion.mjs <agents-demo frames dir>");
const { frames } = JSON.parse(readFileSync(`${dir}/capture.json`, "utf8"));
const width = 960;

const raw = await Promise.all(frames.map((f) => sharp(`${dir}/${f.file}`).resize(width).removeAlpha().raw().toBuffer({ resolveWithObject: true })));
const { height } = raw[0].info;
const out = new URL("../public/motion/", import.meta.url).pathname;
await sharp(Buffer.concat(raw.map((r) => r.data)), { raw: { width, height: height * raw.length, channels: 3, pageHeight: height } })
  .webp({ quality: 80, effort: 6, loop: 0, delay: frames.map((f) => Math.max(16, Math.round(f.hold * 1000))), minSize: true })
  .toFile(`${out}agents.webp`);
await sharp(raw.at(-1).data, { raw: { width, height, channels: 3 } }).webp({ quality: 86 }).toFile(`${out}agents-still.webp`);
console.log(`agents motion: ${frames.length} frames, ${width} × ${height}, ${frames.reduce((s, f) => s + f.hold, 0).toFixed(1)} s`);

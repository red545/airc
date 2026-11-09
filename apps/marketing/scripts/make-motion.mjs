// Turns the social studio's real Capture motion (frames rendered offscreen by `--script social`, see
// tools/social/mac-frames.sh) into the animated WebP the homepage's Capture cell plays, plus a still of its last frame
// for reduced motion. Each frame keeps its own timing from capture.json. The output goes in public/motion/, served as
// is (Astro's image pipeline would keep only the first frame). Re-run after the studio re-renders, and commit both.
//   node scripts/make-motion.mjs [frames dir]   (default: the studio's artifacts/social/_frames/capture)
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
const sharp = createRequire(import.meta.url)("sharp");

const dir = process.argv[2] ?? new URL("../../../../artifacts/social/_frames/capture/", import.meta.url).pathname;
const { frames } = JSON.parse(readFileSync(`${dir}/capture.json`, "utf8"));
// The page area of the 2880 × 1800 window: the hint at the top, the trip page, the selection and its bar.
const box = { left: 480, top: 20, width: 1760, height: 1480 };
const width = 880;

const raw = await Promise.all(
  frames.map((f) => sharp(`${dir}/${f.file}`).extract(box).resize(width).removeAlpha().raw().toBuffer({ resolveWithObject: true })),
);
const { height } = raw[0].info;
const out = new URL("../public/motion/", import.meta.url).pathname;
await sharp(Buffer.concat(raw.map((r) => r.data)), { raw: { width, height: height * raw.length, channels: 3, pageHeight: height } })
  .webp({ quality: 72, effort: 6, loop: 0, delay: frames.map((f) => Math.max(16, Math.round(f.hold * 1000))), minSize: true })
  .toFile(`${out}capture.webp`);
await sharp(raw.at(-1).data, { raw: { width, height, channels: 3 } }).webp({ quality: 82 }).toFile(`${out}capture-still.webp`);
console.log(`motion: ${frames.length} frames, ${width} × ${height}, ${(frames.reduce((s, f) => s + f.hold, 0)).toFixed(1)} s`);

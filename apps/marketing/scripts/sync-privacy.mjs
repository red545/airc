// Copies docs/user/telemetry.md (the app's own account of what it sends) into src/content/telemetry.md, which the
// privacy page renders. It runs before every build. Vercel only receives apps/marketing, so there the docs file is
// absent and the committed copy is used; commit the copy whenever the doc changes.
import { copyFileSync, existsSync, readFileSync } from "node:fs";

const doc = new URL("../../../docs/user/telemetry.md", import.meta.url);
const copy = new URL("../src/content/telemetry.md", import.meta.url);

if (existsSync(doc)) {
  const changed = !existsSync(copy) || readFileSync(doc, "utf8") !== readFileSync(copy, "utf8");
  if (changed) copyFileSync(doc, copy);
  console.log(changed ? "privacy: copied docs/user/telemetry.md" : "privacy: up to date");
} else if (!existsSync(copy)) {
  console.error("privacy: no src/content/telemetry.md and no docs/user/telemetry.md to copy it from");
  process.exit(1);
}

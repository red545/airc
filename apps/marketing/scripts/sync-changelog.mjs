// Copies docs/release-notes-beta.md, the notes of the release being prepared (or the one just published), to
// src/content/changelog/<version>.md, the version from its title ("# Airc 0.1.2 public beta"). It runs before every
// build, so /changelog follows the repo. Earlier releases' files stay as they were committed, and so does a release's
// file once it is the published notes (they end with the "Source: `<commit>`" line the release adds). Vercel only
// receives apps/marketing, so there the docs file is absent and the committed copies are used; commit them.
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const doc = new URL("../../../docs/release-notes-beta.md", import.meta.url);
if (!existsSync(doc)) {
  console.log("changelog: no docs/release-notes-beta.md here, using the committed notes");
  process.exit(0);
}
const text = readFileSync(doc, "utf8");
const version = text.match(/^# Airc (\d+\.\d+\.\d+)\b/m)?.[1];
if (!version) {
  console.error("changelog: docs/release-notes-beta.md has no \"# Airc <version>\" title");
  process.exit(1);
}
const to = new URL(`../src/content/changelog/${version}.md`, import.meta.url);
if (existsSync(to) && /^Source: `[0-9a-f]{7,}`/m.test(readFileSync(to, "utf8"))) {
  console.log(`changelog: ${version} is published, its notes are final`);
} else if (existsSync(to) && readFileSync(to, "utf8") === text) {
  console.log(`changelog: ${version} up to date`);
} else {
  writeFileSync(to, text);
  console.log(`changelog: copied the ${version} notes`);
}

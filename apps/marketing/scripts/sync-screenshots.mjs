// Copies the marketing screenshots the site uses from assets/screenshots/ (the real app on a synthetic demo setup,
// made by scripts/marketing-shots.sh; see its README) into src/assets/screens/. It runs before every build. Vercel only
// receives apps/marketing, so there the source folder is absent and the committed copies are used; commit them
// whenever the shots are refreshed.
import { copyFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";

const used = [
  "media-controls", // Spaces demo: Personal (Mint), on Wikivoyage
  "split-view-3", // Spaces demo: Travel (Sky), and Split View
  "pinned-split", // Spaces demo: Studio (Peach)
  "hero-dark", // Spaces demo: Work (Grape, dark)
  "spaces", // Colours: four Spaces, four colours; also the social card
  "profiles",
  "command-bar-light",
  "command-bar-dark",
  "onboarding-import",
  "peek",
  "split-view-2",
  "picture-in-picture",
  "boosts", // Boosts: Colors
  "boosts-font",
  "boosts-zap",
  "settings-privacy", // the privacy page
  "settings-privacy-events",
];

const src = new URL("../../../assets/screenshots/", import.meta.url);
const dst = new URL("../src/assets/screens/", import.meta.url);
mkdirSync(dst, { recursive: true });

let copied = 0;
for (const name of used) {
  const from = new URL(`${name}.webp`, src);
  const to = new URL(`${name}.webp`, dst);
  if (existsSync(from)) {
    if (!existsSync(to) || !readFileSync(from).equals(readFileSync(to))) {
      copyFileSync(from, to);
      copied++;
    }
  } else if (!existsSync(to)) {
    console.error(`screenshots: ${name}.webp is in neither assets/screenshots nor src/assets/screens`);
    process.exit(1);
  }
}
console.log(copied ? `screenshots: copied ${copied}` : "screenshots: up to date");

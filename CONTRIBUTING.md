# Contributing to Airc

Thanks for helping. Airc is built and maintained by AI agents, with a person deciding what ships. Every report and
patch is read.

## Report a bug or ask for a feature

[Open an issue](../../issues/new/choose). The templates ask for what helps most:

- your Airc version (Airc menu › About Airc) and macOS version;
- the engine: Chromium (the default) or Safari's engine (WebKit);
- the steps, what you expected and what happened;
- a screenshot or screen recording if it's visual.

Issues are public. Never paste passwords, cookies, private URLs, or your Space and tab names. Blur them in
screenshots. For anything private, use **Send Feedback** in Airc (next to the + at the bottom of the sidebar)
instead.

**Security problems:** don't open an issue. Use Send Feedback in Airc, or email hello@aircbrowser.com with
"security" in the subject.

## Send a pull request

This repository is a public mirror. The source of truth is a private repository, and this one is regenerated
from it after every change, so a pull request here can't be merged directly. Instead:

1. Open the pull request here as usual. Keep it small and focused: one fix or one feature.
2. We review it. Only people review contributed code, and no CI runs on it here.
3. If we take it, we apply your commits to the private source with you as the author (or `Co-authored-by:`), run
   the full checks on both engines, and ship it in a release. The change then appears here with the next sync,
   and we close the pull request with a link to the release.

Before you start something big, open an issue first so we can agree on the approach.

### Building

- **App:** Xcode 27 on Apple silicon (see AGENTS.md for the Metal toolchain step); `scripts/build-app.sh`. The Swift packages build and test with
  `swift test --package-path packages/AircKit`.
- **Engine:** building Chromium needs a full Chromium checkout (about 100 GB and several hours). See
  [docs/rebase.md](docs/rebase.md) and [AGENTS.md](AGENTS.md). Most app changes don't need it: use
  `CHROMIUM_OUT` to point at a framework you already have, or build the WebKit engine only.
- Read [AGENTS.md](AGENTS.md) for the code layout and the rules the agents follow; they apply to people too.

### Rules for code

- No personal data anywhere: no real names, emails, account IDs, home-folder paths or tab/Space names in code,
  tests, fixtures or screenshots. Use made-up values (`example.com`, "Synthetic Home"). A privacy scan blocks
  anything else.
- Match Arc's behaviour where Airc copies it, and say in the pull request how you checked.
- Licence: by contributing you agree your work is released under this repository's [LICENSE](LICENSE).

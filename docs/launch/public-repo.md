# Publishing the public repository

At launch Airc becomes public as a **brand-new repository whose only commit is the clean final
tree**. The current private repository and its history stay private for good: old commits still
contain personal data that later commits removed, and a later commit cannot remove it again.
Never push the private repository's branches, tags or history to the public one, never make the
private repository public, and never transfer it.

Everything here runs on the Linux box. No step needs the build Mac.

## The tools (`infra/launch/`)

| Tool | What it does |
|---|---|
| `fresh-repo.sh <out-dir>` | Exports the committed tree at `HEAD` (never the working tree), minus `exclude.txt`, into a new repository at `<out-dir>` with exactly one root commit. Author and committer come from `AIRC_PUBLIC_AUTHOR` (required, no default), the date from `AIRC_PUBLIC_DATE` (default now, always UTC). It uses an isolated git config (no hooks, signing keys or identities from the machine), adds no remote, never pushes, checks the result blob for blob against `HEAD`, then runs `scan.sh` on the tree and on the commit metadata. It exits non-zero if anything fails. The same `HEAD`, author, date and message always give the same commit hash. |
| `scan.sh <dir>` | The privacy and secret gate. It runs gitleaks 8.30.1 (a pinned release, checked against the published checksum and the hash pinned in the script, kept in `tools/` beside the repo) and `scan.py`. `scan.py` greps every file, file name and symlink for the operator's private values and for email addresses that are neither reserved (`example.com`, `.invalid`, `.test` and so on) nor the public mailbox in `apps/marketing/src/lib/site.ts`. Hits print as `file:line: kind`, never the value. |
| `scan-allowlist.txt` | Approved hits, as `path glob<TAB>kind<TAB>reason`. An entry with no reason is rejected, and an entry that no longer matches anything gets a warning. |
| `make-private-patterns.sh` | Writes the private pattern file **outside the repo** (default `private-patterns.txt` beside it, mode 0600). It reads the values from this machine: the tailnet names and IPs of this box and its peers, its hostnames, the local and SSH usernames, home-directory prefixes, the hosts in `~/.ssh/config`, the git and GitHub identities, the Vercel account, team and project IDs, the operator's agent-workspace paths and the private IP ranges. It prints counts only. Lines you add below its marker survive a rerun. |
| `test_scan.sh` | Self-test: it plants fake values (tailnet host and IP, username, home path, PNG metadata, file name, outside symlink, personal email, GitHub token, hand-added Space name) into a temporary copy of `HEAD`, then proves that each one is caught at the right `file:line` and that none appears in the output. It also checks the allowlist and the refusals. |
| `images.sh <dir> <out.html>` | Image review sheet: every committed image with its size, where it is referenced, risky metadata (EXIF/XMP beyond resolution and colour space), OCR text (tesseract if installed, otherwise RapidOCR in a private venv in `tools/`), seen words that occur in no committed file, and flags (emails, handles, local or private URLs, possible personal names). Private values are redacted from the OCR text. One self-contained HTML page with downscaled thumbnails and an approve checkbox per image. |
| `headers.py <dir>` | Lists source files without the Airc header (`Copyright 2026 The Airc Authors` + `SPDX-License-Identifier: Apache-2.0`) or the ArdiaCore one (`Copyright 2026 Mantra Patel` + SPDX + `Modified by The Airc Authors`). |

## What is left out, and why

Exclusion is for **legal or privacy reasons only**. Open source means everything else stays,
including the agent playbook, research notes, QA reviews, measurements and build infrastructure.
Each entry in `infra/launch/exclude.txt` gives its reason:

| Path | Reason |
|---|---|
| `docs/launch-audit.md` | **Privacy.** It is a map into the private history: commit IDs and the kinds of personal data each one holds. It also describes the state of the operator's local machine (an ignored token file and its permissions, build paths in installed bundles). It has no value without the old history. |
| `docs/launch-checklist.md` | **Privacy.** The owner's internal launch to-do list. It names the owner's personal deployment account (a scan hit). Keep it excluded unless the owner scrubs it and wants it public. |

Considered and **kept**:

- `AGENTS.md`, `CLAUDE.md`: how the project is built and maintained (by agents). Part of what
  Airc is. They contain no private values.
- `docs/research/*`, `docs/spec.md`: the claims cite Arc's public help centre and release notes,
  and the third-party measurements are published in ilo. Measurements are facts. The
  bundle-inspection notes themselves were never committed. Three open items remain for the
  owner, listed under the next heading.
- `docs/qa/*`, `engine/PASS*.md`, `engine/perf/*.json`: development records and measurement
  data. They contain no private values (scan clean) and no third-party content beyond short
  citations.
- `infra/nightly.sh`, `scripts/mac.sh`, `infra/updates/*`, `infra/status.py`: the build and
  update infrastructure. These files are parameterised: the hosts, users and paths come from the
  environment, not the files.
- Mockups and marketing screenshots: synthetic fixture content. They still need the owner's
  visual approval on the image sheet.

## Open items for the owner (as of the first dry run, 2026-11-06; resolved before publishing)

1. **Operator workspace paths** (scan kind `operator-path`): `docs/spec.md:19`,
   `docs/research/arc_behavior_spec.md:61` and `docs/research/onboarding_and_import.md:188`
   point at a local agent-workspace folder, and the folder name quotes a private prompt. Replace
   each with a neutral description ("the earlier Chrome extension prototype").
2. **Arc bundle inspection described in `docs/spec.md` §0.1.** The section says the Arc
   installer was unpacked and its binaries and string tables read, and it quotes Arc's copy. The
   notes themselves are not in the repo. Arc's terms may forbid this kind of inspection. Owner
   decision: keep §0.1, reword it as observed behaviour without the method, or drop the method
   sentence.
3. **Arc's UI copy in the app.** Short labels ("Create a Space", "Change Profile") are
   functional and fine. A few full sentences of Arc's copy appear verbatim in the app and the
   mockups, for example the Profiles explanation in `Spaces/CreateProfilePanel.swift`,
   `Settings/SettingsWindow.swift` and `Browser/WindowActions.swift` (under
   `apps/browser/Sources/Airc/`) and in `packages/AircDesign`. Owner decision: keep them for
   parity, or have the app agent rewrite the longer sentences in Airc's own words.
4. **The owner's own Arc setup in `arc_behavior_spec.md`.** The `[S]` claims describe the owner's
   screenshots: the number of Spaces, which Favorites, the theme colour, full-screen use. No names
   or titles appear. They are acceptable unless the owner minds.
5. **Licence headers**: 225 of 380 source files carry no header (none in `engine/core`). `headers.py` gives the list. Add
   the Airc header (`// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0`)
   before launch, or decide that the LICENSE and NOTICE files are enough for the files without a
   header. Never touch the ArdiaCore headers.

## Who approves what

| What | Who | How |
|---|---|---|
| Author identity of the root commit (`AIRC_PUBLIC_AUTHOR`) | **Owner** | Pick a public identity, never a personal address. Recommended: the project mailbox from `site.ts`, e.g. `Airc <hello@…>` with the real domain, or a GitHub noreply address of the publishing account. The commit must not carry a personal name unless the owner wants it to. |
| Public owner and repository name | **Owner** | For example `<org>/airc`. Publishing under an organisation avoids clashing with the private repository's name. |
| `exclude.txt` | **Owner** | Read the table above. Approving it means agreeing that everything else is published. |
| Image sheet | **Owner** | Open `images.html`, look at every image (flagged ones first) and tick each. Every image must be ticked. |
| `scan-allowlist.txt` entries | **Owner**, proposed by the lead | Each entry needs a reason. Today's three entries are false positives (an Android credential URI, a key's file name, a synthetic tailnet host in a test). |
| Hand-added private patterns | **Owner** | Add real Space names, real tab titles, your real name and any other private words below the marker in the pattern file. Never commit that file. |
| Final go: the exact root commit hash | **Owner** | Approve the hash that `fresh-repo.sh` prints. The lead pushes only that hash. |
| Running the steps | **Lead** | Nobody else creates the repository or pushes. |

## Launch night, step by step

Paths below are relative to the folder that contains the private checkout (`airc/`). Run every
command from that folder, **never from inside `airc/`**.

```bash
# 0. Freeze. Every agent and the owner has committed. The checkout is clean and HEAD is the release.
git -C airc status --porcelain            # must print nothing (fresh-repo.sh exports HEAD only)
git -C airc log -1 --format='%H %s'

# 1. Refresh the private patterns, then add hand-added values below the marker.
airc/infra/launch/make-private-patterns.sh
"${EDITOR:-vi}" private-patterns.txt

# 2. Prove the gate still works.
airc/infra/launch/test_scan.sh            # "test_scan: all passed"

# 3. Build the public repository. A fixed date makes the hash reproducible.
rm -rf public-airc
AIRC_PUBLIC_AUTHOR='Airc <public-address-approved-by-owner>' \
AIRC_PUBLIC_DATE='2026-12-01T18:00:00Z' \
  airc/infra/launch/fresh-repo.sh public-airc
#    It must end with "fresh-repo: OK". If the scan fails, fix the files in the private repo,
#    commit, and go back to step 0. Never edit public-airc by hand.

# 4. Image approval: the owner ticks every image.
airc/infra/launch/images.sh public-airc artifacts/publicprep/images.html

# 5. Licence headers (zero misses, or the owner accepts the list).
python3 airc/infra/launch/headers.py public-airc

# 6. Final look at the repository about to be published.
git -C public-airc log --format=fuller    # one commit, approved identity and date
git -C public-airc rev-list --all --count # 1
git -C public-airc remote -v              # nothing
git -C public-airc fsck --strict
git -C public-airc rev-parse HEAD         # the hash the owner approves

# 7. Create the repository PRIVATE first, push the single commit, check it, then make it public.
cd public-airc
[ "$(git rev-list --all --count)" = 1 ] && [ -z "$(git remote)" ] || exit 1
gh repo create <org>/<name> --private \
  --description "An Arc-style browser for macOS, built and maintained by AI" \
  --homepage https://aircbrowser.com \
  --source . --remote origin
git push origin main                      # main only. Never --all, --mirror or --tags.

# 8. Verify on GitHub, then flip it public.
gh api repos/<org>/<name>/commits --jq 'length'          # 1
gh api repos/<org>/<name>/commits/main --jq '.sha'       # the approved hash
gh api repos/<org>/<name>/branches --jq '.[].name'       # main
gh repo edit <org>/<name> --visibility public --accept-visibility-change-consequences
```

Only step 7 creates anything outside this machine. **Agents never run steps 7 and 8.** The lead
runs them after the owner's go.

## After launch (published 2026-11-06)

The public repository (`GITHUB_REPO` in `apps/marketing/src/lib/site.ts`) was created from root commit
`b4fc36a` (private source `b08b14a`). The private repository was renamed, and the private checkout's
`origin` points to its new name. Development stays in the private checkout (owner's decision, 2026-11-06):

- **`infra/launch/sync-public.sh`** publishes the reviewed `origin/main` as one new public commit: the tree at
  that revision minus `exclude.txt`, the same privacy scan as `fresh-repo.sh` on the tree and on the commit
  message (the subjects of the private commits since the last sync), and a fast-forward push of `main`. It
  refuses to run if the public clone holds a private commit or the private checkout points at the public
  repository. The last published private revision is in `../status/public-sync.rev`. Cron runs it hourly.
- The public clone is `../public-airc`; `AIRC_PUBLIC_REMOTE` must equal its origin. Never add the public
  repository as a remote of the private checkout, and never push private branches or tags there.
- The public `main` is protected (no force pushes, no deletion, linear history), with secret scanning and
  push protection on. A push of private history is non-fast-forward and is refused.
- The hand-added private patterns (the owner's real Space and profile names, name) are in
  `../private-patterns.txt`, outside the repo. Add new private words there.

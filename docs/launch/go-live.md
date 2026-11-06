# Go live

Use the owner's [launch checklist](../launch-checklist.md) alongside this sequence;
it remains the owner's file. Technical gates do not approve licences or product claims.

1. **Owner: legal and product clearance.** The permanent public identity is
   `com.aircbrowser.Airc` (D8, confirmed). Approve Widevine/CDM redistribution or ship
   without it; review H.264/AAC terms and FFmpeg/other reciprocal source obligations.
   Approve NOTICE, fonts, marks and screenshots. Keep the Safe Browsing disclosure
   until protection is qualified. Confirm the privacy disclosure for default-on
   telemetry and crash reporting, and the configured/tested macOS distinction.
2. **Lead: freeze and qualify.** Commit the intended tree, pass the package and
   device-free Chromium suite, and run `scripts/release/release.sh`. Review its
   exact source/build, scan, signatures, both Accepted notary logs, quarantine,
   throwaway install, and full/delta Sparkle proofs. The runbook explains the
   retained engine runtime gate. Keep the original signed archives for updates.
3. **Lead: storage and upload (authorized separately from homepage launch).**
   Configure the owner's linked Vercel project and Blob credentials privately.
   Run `upload.sh STAGE --go --create-store` once, then
   `upload.sh STAGE --go`. Check the printed immutable download URLs and hashes.
   The uploader refuses missing green evidence or incomplete qualification.
4. **Owner + homepage thread: public site.** Apply the exact runbook Vercel snippet,
   set the Blob origin, link the download button to `/download`, and finish the
   privacy page. Approve copy and social images. Attach `aircbrowser.com`, verify
   DNS/TLS, then authorize the homepage production deployment. Check `/appcast.xml`,
   `/latest.json`, and `/download` anonymously; download, hash and open the DMG.
   Verify a range request on the ZIP. No agent should attach the domain or deploy
   the homepage as part of packaging.
5. **Owner + lead: public source.** Follow [public-repo.md](public-repo.md): approve
   public identity, exclusions, image review and the exact single root commit from
   `infra/launch/fresh-repo.sh`. Publish only that fresh tree. Never expose the old
   private history. Move development to the public clone after launch.
6. **Owner: announce.** Approve the exact download, public repository, release notes
   and privacy URLs, then announce. Explain Stable versus opt-in Nightly and beta
   limitations. Never announce an unqualified candidate.

After launch, Stable remains manual. The 01:15 UTC wrapper in
`infra/release/nightly.sh` publishes Nightly only after a green run and the same
notarization/installation/update gates. The daytime dev feed stays tailnet-only.
Switching Nightly back to Stable waits for a higher stable build, never a downgrade.
If a release is bad, withdraw its feed entry and ship a higher fixed build; do not
replace artifact bytes or roll a migrated browser profile back.

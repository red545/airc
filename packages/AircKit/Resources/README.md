# AircKit resources

## public_suffix_list.dat

The [Public Suffix List](https://publicsuffix.org/), as Chromium ships it (`net/base/registry_controlled_domains/
effective_tld_names.dat` at the pinned `CHROMIUM_VERSION`). Boosts key sites by it (`PublicSuffixList.swift`,
`BoostDomain`), so a Boost's site is the site Chromium isolates.

- **Licence:** Mozilla Public License 2.0 (the file's own header; https://mozilla.org/MPL/2.0/). It is kept here
  unmodified, as its Source Code Form. It is not Apache-2.0 like the rest of the repo.
- **In the app:** `scripts/build-app.sh` puts it in `Contents/Resources/public_suffix_list.dat.deflate` (raw DEFLATE,
  read with `NSData.decompressed(using: .zlib)`). Without it the app keys every Boost by its exact host.
- **Refresh:** `scripts/refresh-public-suffix-list.sh` (from the Chromium checkout, or `--upstream` from
  publicsuffix.org), then run the AircKit tests and commit the file.

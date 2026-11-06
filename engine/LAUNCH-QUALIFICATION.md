# Launch qualification follow-up

The launchfix pass does not rebuild Chromium. The next nightly must use
`generate_about_credits = true` from `engine/build.sh`. Chromium's
`components/resources/BUILD.gn` otherwise defaults this to `is_official_build`
(false in Airc). Both inspected output variants had the 401-byte sample page at
`gen/components/resources/about_credits.html`. The generated page is consumed by
`IDR_ABOUT_UI_CREDITS_HTML` (Brotli compression in the resource pack), so a raw/gzip
search alone cannot qualify it. After rebuilding, verify offline `chrome://credits`
and `about:credits`, and retain the build-matched page in the licence directory.
A scratch host navigated to `chrome://credits` against the existing release framework:
title `Credits`, sample-page flag true, 165 body characters, applicationActive false.
This confirms navigation works but the current licence inventory is missing.

Review reciprocal dependencies and corresponding-source/relinking requirements
separately; copying the Chromium top-level LICENSE does not settle those duties.

The current output frameworks contain the generic home-root literal from
`components/url_formatter/url_fixer.cc`, `FixupHomedir`, not an operator's home.
The strict bundle scan intentionally flags this too. Do not patch binary bytes or
weaken the gate silently: agree a source-level treatment for this upstream URL
behavior before declaring the whole framework clean. Chromium's compiler config
already maps Swift file prefixes and Clang compilation directories when
`strip_absolute_paths_from_debug_symbols` is enabled (the macOS default without
dSYMs); setting it as an unconditional GN argument is invalid on that default.
Debug symbols stay outside the distribution. Rescan next nightly's exact output.

The scan also rejects literal `AircDevChannel` and `AircLaunchArguments` readers in
the Swift executable. Compile-time separation of development/test functionality
is assigned to a later app pass. This gate must continue to block public packaging
until that pass is complete. No production signing or publishing was attempted.

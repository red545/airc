#!/bin/bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
set -euo pipefail
usage() { echo 'Usage: notarize.sh --profile KEYCHAIN_PROFILE [--dry-run] FILE.dmg|FILE.zip [APP_TO_STAPLE]'; }
profile= dry=0
while [[ $# -gt 0 ]]; do
 case "$1" in
 --profile) [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }; profile=$2; shift 2;;
 --dry-run) dry=1; shift;;
 --help) usage; exit 0;;
 --*) usage >&2; exit 2;;
 *) break;;
 esac
done
[[ -n "$profile" && $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 2; }
archive=$1; target=${2:-$1}
case "$archive" in *.dmg|*.zip) ;; *) usage >&2; exit 2;; esac
[[ "$target" == *.app || "$target" == *.dmg ]] || { echo 'ZIP submissions require an APP_TO_STAPLE argument.' >&2; exit 2; }
if [[ $dry == 1 ]]; then
 printf 'xcrun notarytool submit %q --keychain-profile %q --wait\n' "$archive" "$profile"
 printf 'xcrun stapler staple %q\n' "$target"; exit 0
fi
[[ -e "$archive" && -e "$target" ]] || { echo 'Submission/staple target missing.' >&2; exit 2; }
notary_args=()
[[ -z ${AIRC_NOTARY_KEYCHAIN:-} ]] || notary_args=(--keychain "$AIRC_NOTARY_KEYCHAIN")
xcrun notarytool history --keychain-profile "$profile" ${notary_args[@]+"${notary_args[@]}"} >/dev/null || {
 echo "No usable notarization credentials for profile '$profile'. Run notarytool store-credentials first." >&2; exit 1;
}
result=$(mktemp "${archive}.notary.XXXXXX")
trap 'rm -f "$result"' EXIT
xcrun notarytool submit "$archive" --keychain-profile "$profile" ${notary_args[@]+"${notary_args[@]}"} --wait --output-format plist > "$result"
submission=$(/usr/libexec/PlistBuddy -c 'Print :id' "$result")
xcrun notarytool log "$submission" --keychain-profile "$profile" ${notary_args[@]+"${notary_args[@]}"} "$archive.notary-log.json"
status=$(/usr/libexec/PlistBuddy -c 'Print :status' "$result")
printf 'Notarization status: %s; submission: %s\n' "$status" "$submission"
[[ "$status" == Accepted ]] || { cat "$result"; echo 'Notarization was not Accepted; nothing stapled.' >&2; exit 1; }
xcrun stapler staple "$target"
xcrun stapler validate "$target"

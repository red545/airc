#!/usr/bin/env bash
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Run on the build Mac ONLY after the lead approves the one-time installation.
#   infra/updates/install.sh [APP]   install a dev-channel Chromium build as ~/Applications/Airc.app
# AIRC_INSTALL_DIR=<dir> installs into <dir> instead (an update proof's throwaway folder).
# Every check ends in `|| fail`: macOS's bash 3.2 doesn't stop a set -e script on a false [[ ]].
set -euo pipefail
fail() { echo "install.sh: $*" >&2; exit 1; }
APP=${1:-build/Airc-Chromium.app}
DIR=${AIRC_INSTALL_DIR:-$HOME/Applications}
DEST="$DIR/Airc.app"
readkey() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Contents/Info.plist" 2>/dev/null || true; }
[[ ! -e "$DEST" ]] || fail 'Installation already exists; use Sparkle to update it.'
[[ $(readkey AircDevChannel) == true ]] || fail "$APP is not a dev-channel build"
[[ $(readkey AircDefaultEngine) == chromium ]] || fail "$APP is not the Chromium bundle"
codesign --verify --deep --strict "$APP"
mkdir -p "$DIR"
STAGE=$(mktemp -d "$DIR/.airc-install.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Airc.app"
codesign --verify --deep --strict "$STAGE/Airc.app"
mv -n "$STAGE/Airc.app" "$DEST"
[[ -d "$DEST" && ! -e "$STAGE/Airc.app" ]] || fail "could not move the app to $DEST"
echo "Installed $DEST. Open this copy for future automatic updates."

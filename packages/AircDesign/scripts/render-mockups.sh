#!/bin/zsh
# Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
# Renders docs/design/mockups/*.html to PNGs with WebKit (the gallery's --html mode) into build/mockups, and crops
# the onboarding and profiles frames and the translucent window states. Run from the repo root on the Mac.
set -e
G=$PWD/packages/AircDesign/.build/debug/aircdesign-gallery
M=$PWD/docs/design/mockups
O=$PWD/build/mockups
mkdir -p $O
$G --html $M/onboarding.html $O/onboarding.png 1440 5776
$G --html $M/window.html $O/window.png 1440 3808
$G --html $M/command-bar.html $O/command-bar.png 1440 900
$G --html $M/space-switch.html $O/space-switch.png 1440 900
$G --html $M/profiles.html $O/profiles.png 1440 12468
names=(create-space create-space-states pill-menu create-profile-1 create-profile-2 theme-picker indicator sign-in sign-in-steps
       create-space-dark create-profile-1-dark create-profile-2-dark theme-picker-dark)
for i in {0..12}; do
  sips -c 1800 2880 --cropOffset $(( (56 + i * 956) * 2 )) 0 $O/profiles.png --out $O/profiles-${names[$((i + 1))]}.png >/dev/null
done
for i in 0 1 2 3 4 5; do
  sips -c 1800 2880 --cropOffset $(( (56 + i * 956) * 2 )) 0 $O/onboarding.png --out $O/ob-$((i + 1)).png >/dev/null
done
sips -c 1800 2880 --cropOffset $(( (900 + 56) * 2 )) 0 $O/window.png --out $O/window-translucent-subtle.png >/dev/null
sips -c 1800 2880 --cropOffset $(( (900 + 956 + 56) * 2 )) 0 $O/window.png --out $O/window-translucent-more.png >/dev/null
sips -c 1800 2880 --cropOffset $(( (900 + 2 * 956 + 56) * 2 )) 0 $O/window.png --out $O/window-favorites.png >/dev/null
ls $O

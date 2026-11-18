// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#ifndef AIRC_CORE_AIRC_PASSWORDS_H_
#define AIRC_CORE_AIRC_PASSWORDS_H_
class Profile;
namespace airc {
// False when the app turned Airc's own password filling off for the profile
// (Settings › Passwords; AircProfile.passwordsFilled), so a password manager's
// extension has the fields to itself: no fill on page load, no suggestions, no
// saving (ChromePasswordManagerClient::IsFillingEnabled, patch 040). Off-the-
// record profiles follow their original. The app sets it at every launch.
bool PasswordFillingAllowed(const Profile* profile);
}
#endif

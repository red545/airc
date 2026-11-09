// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#ifndef AIRC_CORE_AIRC_PASSKEYS_H_
#define AIRC_CORE_AIRC_PASSKEYS_H_
#include <string>
#include "base/functional/callback_forward.h"
class Profile;
namespace device::fido::mac { struct AuthenticatorConfig; }
namespace airc {
// Derived from the main executable's signed application identifier, never a
// compiled-in developer team or Chromium's bundle identifier.
std::string PasskeyAccessGroup();
bool DeleteLocalPasskeyCredentials(device::fido::mac::AuthenticatorConfig config);
void DeleteProfilePasskeys(Profile* profile, base::OnceCallback<void(bool)> done);
}
#endif

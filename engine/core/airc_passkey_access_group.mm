// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#include "airc/core/airc_passkeys.h"
#include <Security/Security.h>
#include "base/apple/scoped_cftyperef.h"
#include "base/strings/sys_string_conversions.h"
#include "crypto/apple/keychain_util.h"
namespace airc {
std::string PasskeyAccessGroup() {
  base::apple::ScopedCFTypeRef<SecTaskRef> task(SecTaskCreateFromSelf(nullptr));
  if (!task) return {};
  base::apple::ScopedCFTypeRef<CFTypeRef> identifier(
      SecTaskCopyValueForEntitlement(task.get(),
          CFSTR("com.apple.application-identifier"), nullptr));
  if (!identifier || CFGetTypeID(identifier.get()) != CFStringGetTypeID()) return {};
  std::string group = base::SysCFStringRefToUTF8(
      static_cast<CFStringRef>(identifier.get())) + ".webauthn";
  return crypto::apple::ExecutableHasKeychainAccessGroupEntitlement(group) ? group : std::string();
}

}

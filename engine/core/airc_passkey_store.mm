// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#include "airc/core/airc_passkeys.h"
#import <Foundation/Foundation.h>
#include <Security/Security.h>
#include "base/apple/bridging.h"
#include "base/apple/scoped_cftyperef.h"
#include "base/strings/sys_string_conversions.h"
#include "base/time/time.h"
#include "device/fido/mac/credential_store.h"

namespace airc {
bool DeleteLocalPasskeyCredentials(device::fido::mac::AuthenticatorConfig config) {
  device::fido::mac::TouchIdCredentialStore store(config);
  if (store.DeleteCredentialsSync(base::Time::Min(), base::Time::Max())) return true;
  // M156's DeleteCredentialsSync reports false for an entirely empty access
  // group as well as real errors. Distinguish that case; never treat a locked
  // Keychain or a missing entitlement as successful deletion.
  using base::apple::CFToNSPtrCast;
  NSDictionary* query = @{
      CFToNSPtrCast(kSecClass): CFToNSPtrCast(kSecClassKey),
      CFToNSPtrCast(kSecAttrAccessGroup): base::SysUTF8ToNSString(config.keychain_access_group),
      CFToNSPtrCast(kSecMatchLimit): CFToNSPtrCast(kSecMatchLimitOne),
      CFToNSPtrCast(kSecReturnAttributes): @YES,
      CFToNSPtrCast(kSecUseAuthenticationUI): CFToNSPtrCast(kSecUseAuthenticationUIFail),
  };
  base::apple::ScopedCFTypeRef<CFTypeRef> result;
  return SecItemCopyMatching(base::apple::NSToCFPtrCast(query),
                            result.InitializeInto()) == errSecItemNotFound;
}
}

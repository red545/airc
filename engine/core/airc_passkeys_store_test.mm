// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Standalone signed fixture: no browser, no owner data and no authentication UI.
// Since 035-passkeys-touch-id.patch, new keys need the user (Touch ID or the
// Mac's password) for every signature; the check below proves it without UI.
#include <cstdio>
#include <Security/Security.h>
#import <Foundation/Foundation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#include "base/strings/sys_string_conversions.h"
#include "airc/core/airc_passkeys.h"
#include "base/at_exit.h"
#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/run_loop.h"
#include "base/task/single_thread_task_executor.h"
#include "base/task/thread_pool/thread_pool_instance.h"
#include "device/fido/mac/touch_id_context.h"
#include "device/fido/mac/icloud_keychain.h"
#include "base/time/time.h"
#include "device/fido/mac/credential_metadata.h"
#include "device/fido/mac/credential_store.h"
#include "device/fido/public/public_key_credential_user_entity.h"

int main(int argc, const char** argv) {
  base::AtExitManager exit_manager;
  base::CommandLine::Init(argc, argv);
  const auto group = airc::PasskeyAccessGroup();
  if (group.empty()) {
    puts("FAIL: signed WebAuthn group unavailable");
    return 1;
  }
  base::SingleThreadTaskExecutor executor;
  base::ThreadPoolInstance::CreateAndStartWithDefaultParams("PasskeyProbe");
  using device::fido::mac::TouchIdCredentialStore;
  device::fido::mac::AuthenticatorConfig a{
      .keychain_access_group = group,
      .metadata_secret = device::fido::mac::GenerateCredentialMetadataSecret()};
  bool available = false;
  base::RunLoop loop;
  device::fido::mac::TouchIdContext::TouchIdAvailable(a,
      base::BindOnce([](bool* out, base::RunLoop* loop, bool value) {
        *out = value;
        loop->Quit();
      }, &available, &loop));
  loop.Run();
  printf("Platform authenticator available: %s; iCloud entitlement supported: %s\n",
      available ? "yes" : "no",
      device::fido::icloud_keychain::IsSupported() ? "yes" : "no");
  auto b = a;
  b.metadata_secret = device::fido::mac::GenerateCredentialMetadataSecret();
  TouchIdCredentialStore first(a), second(b);
  device::PublicKeyCredentialUserEntity user({1, 2, 3}, "fixture", "Passkey fixture");
  auto ca = first.CreateCredential("passkeys.invalid", user, TouchIdCredentialStore::kDiscoverable);
  auto cb = second.CreateCredential("passkeys.invalid", user, TouchIdCredentialStore::kDiscoverable);
  auto rows_a = first.FindResidentCredentials("passkeys.invalid");
  auto rows_b = second.FindResidentCredentials("passkeys.invalid");
  bool isolated = ca && cb && rows_a && rows_b && rows_a->size() == 1 && rows_b->size() == 1 &&
      rows_a->front().credential_id == ca->first.credential_id &&
      rows_b->front().credential_id == cb->first.credential_id;
  // Presence binding on the real Secure Enclave key. The context forbids any
  // UI, so this never shows a Touch ID or password sheet: a key that requires
  // the user must refuse to sign, while an unbound key (Chromium's upstream
  // default) would sign straight away.
  bool presence_bound = false;
  if (ca) {
    LAContext* no_ui = [[LAContext alloc] init];
    no_ui.interactionNotAllowed = YES;
    NSData* label = [NSData dataWithBytes:ca->first.credential_id.data()
                                   length:ca->first.credential_id.size()];
    NSDictionary* query = @{
      (__bridge id)kSecClass : (__bridge id)kSecClassKey,
      (__bridge id)kSecAttrAccessGroup : base::SysUTF8ToNSString(group),
      (__bridge id)kSecAttrApplicationLabel : label,
      (__bridge id)kSecReturnRef : @YES,
      (__bridge id)kSecUseDataProtectionKeychain : @YES,
      (__bridge id)kSecUseAuthenticationContext : no_ui,
    };
    CFTypeRef found = nullptr;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &found);
    base::apple::ScopedCFTypeRef<SecKeyRef> key(static_cast<SecKeyRef>(const_cast<void*>(found)));
    if (status == errSecSuccess && key) {
      const UInt8 challenge[] = {7, 8, 9, 10};
      base::apple::ScopedCFTypeRef<CFDataRef> message(
          CFDataCreate(nullptr, challenge, sizeof(challenge)));
      base::apple::ScopedCFTypeRef<CFErrorRef> error;
      base::apple::ScopedCFTypeRef<CFDataRef> signature(SecKeyCreateSignature(
          key.get(), kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
          message.get(), error.InitializeInto()));
      const long code = error ? CFErrorGetCode(error.get()) : 0;
      presence_bound = !signature && error;
      printf("Sign without the user: %s (error %ld)\n",
             signature ? "SIGNED, key not bound to the user" : "refused", code);
    } else {
      // Item lookup itself refusing without UI also proves the binding.
      presence_bound = status == errSecInteractionNotAllowed;
      printf("Key lookup without UI: status %d\n", static_cast<int>(status));
    }
  }
  bool deleted = airc::DeleteLocalPasskeyCredentials(a);
  rows_a = first.FindResidentCredentials("passkeys.invalid");
  rows_b = second.FindResidentCredentials("passkeys.invalid");
  bool retained = rows_a && rows_b && rows_a->empty() && rows_b->size() == 1;
  bool cleaned = airc::DeleteLocalPasskeyCredentials(b) &&
      airc::DeleteLocalPasskeyCredentials(a) && airc::DeleteLocalPasskeyCredentials(b);
  printf("%s: signed Secure Enclave create, key needs Touch ID or password to sign, resident enumeration, profile-secret isolation, scoped deletion, survivor, cleanup\n",
      available && isolated && presence_bound && deleted && retained && cleaned ? "PASS" : "FAIL");
  base::ThreadPoolInstance::Get()->Shutdown();
  return available && isolated && presence_bound && deleted && retained && cleaned ? 0 : 1;
}

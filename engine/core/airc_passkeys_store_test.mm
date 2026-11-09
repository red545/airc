// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Standalone signed fixture: no browser, no owner data and no authentication UI.
#include <cstdio>
#include <Security/Security.h>
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
  bool signature_ok = false;
  if (ca) {
    const UInt8 challenge[] = {7, 8, 9, 10};
    base::apple::ScopedCFTypeRef<CFDataRef> message(
        CFDataCreate(nullptr, challenge, sizeof(challenge)));
    base::apple::ScopedCFTypeRef<CFDataRef> signature(SecKeyCreateSignature(
        ca->first.private_key.get(), kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
        message.get(), nullptr));
    signature_ok = signature && SecKeyVerifySignature(ca->second.get(),
        kSecKeyAlgorithmECDSASignatureMessageX962SHA256, message.get(), signature.get(), nullptr);
  }
  bool deleted = airc::DeleteLocalPasskeyCredentials(a);
  rows_a = first.FindResidentCredentials("passkeys.invalid");
  rows_b = second.FindResidentCredentials("passkeys.invalid");
  bool retained = rows_a && rows_b && rows_a->empty() && rows_b->size() == 1;
  bool cleaned = airc::DeleteLocalPasskeyCredentials(b) &&
      airc::DeleteLocalPasskeyCredentials(a) && airc::DeleteLocalPasskeyCredentials(b);
  printf("%s: signed Secure Enclave create/sign/verify, resident enumeration, profile-secret isolation, scoped deletion, survivor, cleanup\n",
      available && isolated && signature_ok && deleted && retained && cleaned ? "PASS" : "FAIL");
  base::ThreadPoolInstance::Get()->Shutdown();
  return available && isolated && signature_ok && deleted && retained && cleaned ? 0 : 1;
}

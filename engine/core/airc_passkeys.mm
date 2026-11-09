// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#include "airc/core/airc_passkeys.h"
#import <Foundation/Foundation.h>
#include <Security/Security.h>
#include "base/apple/bridging.h"
#include "base/apple/scoped_cftyperef.h"
#include "base/base64.h"
#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/keep_alive/scoped_profile_keep_alive.h"
#include "chrome/browser/profiles/keep_alive/profile_keep_alive_types.h"
#include "chrome/browser/webauthn/webauthn_pref_names.h"
#include "components/prefs/pref_service.h"
#include "crypto/apple/keychain_util.h"
#include "device/fido/mac/credential_store.h"

namespace airc {

void DeleteProfilePasskeys(Profile* profile, base::OnceCallback<void(bool)> done) {
  std::string secret = profile->GetPrefs()->GetString(
      webauthn::pref_names::kWebAuthnTouchIdMetadataSecretPrefName);
  // Ad-hoc builds cannot have created credentials in the signed access group.
  // Do not generate a new metadata secret while deleting a profile.
  std::string group = PasskeyAccessGroup();
  if (secret.empty() || group.empty()) {
    std::move(done).Run(true);
    return;
  }
  if (!base::Base64Decode(secret, &secret)) {
    std::move(done).Run(false);
    return;
  }
  auto keep_alive = ScopedProfileKeepAlive::TryAcquire(
      profile, ProfileKeepAliveOrigin::kProfileDeletionProcess);
  if (!keep_alive) {
    std::move(done).Run(false);
    return;
  }
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskShutdownBehavior::BLOCK_SHUTDOWN},
      base::BindOnce([](std::string group, std::string secret) {
        return DeleteLocalPasskeyCredentials({
            .keychain_access_group = std::move(group),
            .metadata_secret = std::move(secret)});
      }, std::move(group), std::move(secret)),
      base::BindOnce([](std::unique_ptr<ScopedProfileKeepAlive> keep_alive,
                        base::OnceCallback<void(bool)> done, bool ok) {
        std::move(done).Run(ok);
      }, std::move(keep_alive), std::move(done)));
}
}

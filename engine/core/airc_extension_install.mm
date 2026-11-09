// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#import "airc/core/airc_internal.h"
#include "airc/core/airc_launch_switches.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/browser/extensions/webstore_install_with_prompt.h"
#include "chrome/browser/extensions/extension_install_prompt.h"
#include "chrome/browser/profiles/profile.h"
#include "extensions/browser/crx_installer.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/management_policy.h"
#include "extensions/common/extension.h"
#include "extensions/browser/install/crx_install_error.h"
#include "extensions/browser/install_prompt_data.h"
#include "extensions/browser/webstore_install_result.h"
#include "components/crx_file/id_util.h"

namespace {
// The upstream standalone installer flattens policy rejection to OTHER_ERROR.
// Ask the same management providers before showing permission UI, preserving the
// typed policy result while leaving Chromium's later install checks intact.
class ProfileStoreInstaller : public extensions::WebstoreInstallWithPrompt {
 public:
  using WebstoreInstallWithPrompt::WebstoreInstallWithPrompt;
 protected:
  bool ShouldShowPostInstallUI() const override { return false; }
  void OnManifestParsed() override {
    parsed_ = GetLocalizedExtensionForDisplay();
    if (!parsed_) {
      CompleteInstall(extensions::webstore_install::INVALID_MANIFEST, "Invalid extension manifest.");
      return;
    }
    auto alive = profile()->GetWeakPtr();
    extensions::ExtensionSystem::Get(profile())->management_policy()->UserMayInstall(parsed_,
        base::BindOnce([](scoped_refptr<ProfileStoreInstaller> self,
                          base::WeakPtr<Profile> alive,
                          extensions::ManagementPolicy::Decision decision) {
          if (!alive) return;  // Upstream has already completed the shutdown callback.
          if (!decision.allowed) {
            self->CompleteInstall(extensions::webstore_install::BLOCKED_BY_POLICY,
                                  base::UTF16ToUTF8(decision.error));
            return;
          }
          self->ProceedWithInstallPrompt();
        }, base::WrapRefCounted(this), alive));
  }
  void CompleteInstall(extensions::webstore_install::Result result,
                       const std::string& error) override {
    if (result == extensions::webstore_install::OTHER_ERROR && parsed_ &&
        !extensions::ExtensionSystem::Get(profile())->management_policy()->UserMayLoad(parsed_.get())) {
      result = extensions::webstore_install::BLOCKED_BY_POLICY;
    }
    WebstoreInstallWithPrompt::CompleteInstall(result, error);
  }
 private:
  scoped_refptr<const extensions::Extension> parsed_;
};
using Done = void (^)(NSDictionary<NSString*, NSString*>*);
void Finish(Done done, NSString* status, NSString* reason = @"") {
  done(@{@"status": status, @"reason": reason});
}
bool Ready(Profile* profile, NSString* identifier, Done done) {
  if (!profile || profile->IsOffTheRecord()) {
    Finish(done, @"failed", @"A regular profile is required."); return false;
  }
  auto id = base::SysNSStringToUTF8(identifier);
  if (!crx_file::id_util::IdIsValid(id)) {
    Finish(done, @"failed", @"Invalid extension ID."); return false;
  }
  if (extensions::ExtensionRegistry::Get(profile)->GetInstalledExtension(id)) {
    Finish(done, @"alreadyInstalled"); return false;
  }
  return true;
}
}

@implementation AircProfile (ExtensionInstall)
- (void)installWebStoreExtension:(NSString*)identifier parentWindow:(NSWindow*)window
    completion:(Done)done {
  Profile* profile = self.chromeProfile;
  if (!Ready(profile, identifier, done)) return;
  auto installer = base::MakeRefCounted<ProfileStoreInstaller>(
      base::SysNSStringToUTF8(identifier), profile, gfx::NativeWindow(window),
      base::BindOnce([](Done completion, bool success, const std::string& reason,
                        extensions::webstore_install::Result result) {
        using namespace extensions::webstore_install;
        NSString* status = success ? @"installed" :
            result == USER_CANCELLED ? @"denied" :
            result == BLOCKED_BY_POLICY ? @"blockedByPolicy" : @"failed";
        Finish(completion, status, base::SysUTF8ToNSString(reason));
      }, done));
  installer->BeginInstall();
}

- (void)installExtensionFixture:(NSString*)path extensionID:(NSString*)identifier
    parentWindow:(NSWindow*)window completion:(Done)done {
  if (!airc::TestInstance()) {
    Finish(done, @"failed", @"Test instance required."); return;
  }
  Profile* profile = self.chromeProfile;
  if (!Ready(profile, identifier, done)) return;
  auto installer = extensions::CrxInstaller::Create(profile,
      std::make_unique<ExtensionInstallPrompt>(profile, gfx::NativeWindow(window),
          std::make_unique<extensions::InstallPromptData>(
              extensions::InstallPromptData::INSTALL_PROMPT)));
  installer->set_expected_id(base::SysNSStringToUTF8(identifier));
  installer->set_off_store_install_allow_reason(
      extensions::CrxInstaller::OffStoreInstallAllowedFromSettingsPage);
  installer->set_install_immediately(true);
  installer->AddInstallerCallback(base::BindOnce(
      [](Done completion, const std::optional<extensions::CrxInstallError>& error) {
        using Detail = extensions::CrxInstallErrorDetail;
        NSString* status = !error ? @"installed" :
            error->detail() == Detail::USER_CANCELED ? @"denied" :
            error->detail() == Detail::DISALLOWED_BY_POLICY ? @"blockedByPolicy" : @"failed";
        Finish(completion, status, error ? base::SysUTF16ToNSString(error->message()) : @"");
      }, done));
  installer->InstallCrx(base::FilePath(base::SysNSStringToUTF8(path)));
}
@end

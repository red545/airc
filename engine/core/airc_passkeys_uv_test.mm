// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Standalone check of when Airc's profile passkeys ask for Touch ID or the
// Mac's password. LocalAuthentication is replaced at Chromium's own seam
// (ScopedTouchIdTestEnvironment) and keys live in its fake keychain, so this
// shows no system prompt, needs no signing and touches no real Keychain item.
// A real Touch ID or password check needs a person: see engine/PASSKEYS.md.
#include <iostream>
#include <optional>
#include <string>
#include <vector>

#include "base/at_exit.h"
#include "base/files/file_path.h"
#include "base/memory/ref_counted_memory.h"
#include "base/command_line.h"
#include "base/functional/bind.h"
#include "base/run_loop.h"
#include "base/task/single_thread_task_executor.h"
#include "base/task/thread_pool/thread_pool_instance.h"
#include "device/fido/authenticator_get_assertion_response.h"
#include "device/fido/authenticator_make_credential_response.h"
#include "device/fido/ctap_get_assertion_request.h"
#include "device/fido/ctap_make_credential_request.h"
#include "device/fido/mac/credential_metadata.h"
#include "device/fido/mac/credential_store.h"
#include "device/fido/mac/get_assertion_operation.h"
#include "device/fido/mac/make_credential_operation.h"
#include "device/fido/mac/scoped_touch_id_test_environment.h"
#include "device/fido/mac/util.h"
#include "device/fido/public/fido_constants.h"
#include "device/fido/public/public_key_credential_descriptor.h"
#include "device/fido/public/public_key_credential_params.h"
#include "device/fido/public/public_key_credential_rp_entity.h"
#include "device/fido/public/public_key_credential_user_entity.h"
#include "ui/base/resource/resource_bundle.h"
#include "ui/gfx/image/image.h"

namespace {

using device::AuthenticatorMakeCredentialResponse;
using device::GetAssertionStatus;
using device::MakeCredentialStatus;
using device::UserVerificationRequirement;
using namespace device::fido::mac;

constexpr char kRpId[] = "passkeys.invalid";
constexpr char kClientData[] = R"({"type":"webauthn.create"})";

// Every string is a placeholder; the prompt text isn't under test here.
class Strings : public ui::ResourceBundle::Delegate {
 public:
  base::FilePath GetPathForResourcePack(const base::FilePath& p,
                                        ui::ResourceScaleFactor) override {
    return p;
  }
  gfx::Image GetImageNamed(int) override { return {}; }
  gfx::Image GetNativeImageNamed(int) override { return {}; }
  bool HasDataResource(int) const override { return false; }
  scoped_refptr<base::RefCountedMemory> LoadDataResourceBytes(
      int, ui::ResourceScaleFactor) override {
    return nullptr;
  }
  std::optional<std::string> LoadDataResourceString(int) override {
    return std::nullopt;
  }
  bool GetRawDataResource(int, ui::ResourceScaleFactor,
                          std::string_view*) const override {
    return false;
  }
  bool GetLocalizedString(int, std::u16string* value) const override {
    *value = u"verify your identity on $1";
    return true;
  }
};

int g_failures = 0;
void Check(bool ok, const std::string& what) {
  std::cout << (ok ? "PASS: " : "FAIL: ") << what << std::endl;
  if (!ok) {
    ++g_failures;
  }
}

struct MakeResult {
  MakeCredentialStatus status;
  std::optional<AuthenticatorMakeCredentialResponse> response;
};

MakeResult Make(TouchIdCredentialStore* store, UserVerificationRequirement uv) {
  device::CtapMakeCredentialRequest request(
      kClientData, device::PublicKeyCredentialRpEntity(kRpId),
      device::PublicKeyCredentialUserEntity({1, 2, 3}, "fixture",
                                            "Passkey fixture"),
      device::PublicKeyCredentialParams(
          {{device::PublicKeyCredentialParams::CredentialInfo()}}));
  request.user_verification = uv;
  request.resident_key_required = true;
  std::optional<MakeResult> result;
  base::RunLoop loop;
  MakeCredentialOperation op(
      std::move(request), store,
      base::BindOnce(
          [](std::optional<MakeResult>* out, base::RunLoop* loop,
             MakeCredentialStatus status,
             std::optional<AuthenticatorMakeCredentialResponse> response) {
            out->emplace(MakeResult{status, std::move(response)});
            loop->Quit();
          },
          &result, &loop));
  op.Run();
  if (!result) {
    loop.Run();
  }
  return std::move(*result);
}

struct GetResult {
  GetAssertionStatus status;
  std::vector<device::AuthenticatorGetAssertionResponse> responses;
};

GetResult Get(TouchIdCredentialStore* store, UserVerificationRequirement uv,
              const std::vector<uint8_t>* only) {
  device::CtapGetAssertionRequest request(kRpId, kClientData);
  request.user_verification = uv;
  if (only) {
    // An allow list is what conditional (autofill) sign-in sends once the
    // person picks a passkey in the field's dropdown.
    request.allow_list.emplace_back(device::CredentialType::kPublicKey, *only);
  }
  std::optional<GetResult> result;
  base::RunLoop loop;
  GetAssertionOperation op(
      std::move(request), store,
      base::BindOnce(
          [](std::optional<GetResult>* out, base::RunLoop* loop,
             GetAssertionStatus status,
             std::vector<device::AuthenticatorGetAssertionResponse> r) {
            out->emplace(GetResult{status, std::move(r)});
            loop->Quit();
          },
          &result, &loop));
  op.Run();
  if (!result) {
    loop.Run();
  }
  return std::move(*result);
}

}  // namespace

int main(int argc, const char** argv) {
  base::AtExitManager exit_manager;
  base::CommandLine::Init(argc, argv);
  base::SingleThreadTaskExecutor executor;
  base::ThreadPoolInstance::CreateAndStartWithDefaultParams("PasskeyUv");
  Strings strings;
  ui::ResourceBundle::InitSharedInstanceWithLocale(
      "en-US", &strings, ui::ResourceBundle::DO_NOT_LOAD_COMMON_RESOURCES);

  AuthenticatorConfig config{
      .keychain_access_group = "test.org.airc.webauthn",
      .metadata_secret = GenerateCredentialMetadataSecret()};
  ScopedTouchIdTestEnvironment env(config);
  TouchIdCredentialStore store(config);

  for (bool touch_id : {false, true}) {
    ScopedBiometricsOverride biometrics(touch_id);
    const char* mac = touch_id ? "Touch ID ready" : "no Touch ID (password)";
    for (auto uv : {UserVerificationRequirement::kDiscouraged,
                    UserVerificationRequirement::kPreferred,
                    UserVerificationRequirement::kRequired}) {
      const char* uv_name =
          uv == UserVerificationRequirement::kDiscouraged ? "discouraged"
          : uv == UserVerificationRequirement::kPreferred ? "preferred"
                                                          : "required";
      std::string what = std::string(mac) + ", uv=" + uv_name;
      Check(ProfileAuthenticatorWillDoUserVerification(uv, touch_id),
            what + ": Airc decides to verify the user");

      // Creating: the person cancels the macOS sheet.
      env.SimulateTouchIdPromptFailure();
      MakeResult cancelled = Make(&store, uv);
      Check(cancelled.status == MakeCredentialStatus::kUserConsentDenied &&
                !cancelled.response,
            what + ": create asks first; cancel saves nothing");

      // Creating: Touch ID or the password succeeds.
      env.SimulateTouchIdPromptSuccess();
      MakeResult made = Make(&store, uv);
      const bool made_ok =
          made.status == MakeCredentialStatus::kSuccess && made.response;
      Check(made_ok && made.response->attestation_object.authenticator_data()
                           .obtained_user_verification(),
            what + ": create succeeds with UV flag set");
      if (!made_ok) {
        continue;
      }
      std::vector<uint8_t> id = made.response->attestation_object
                                    .GetCredentialId();

      // Signing in from the modal picker (empty allow list), then from the
      // autofill dropdown (the chosen credential), each cancelled then passed.
      const std::vector<uint8_t>* const chosen = &id;
      for (const std::vector<uint8_t>* only :
           {static_cast<const std::vector<uint8_t>*>(nullptr), chosen}) {
        const char* where = only ? "autofill sign-in" : "picker sign-in";
        env.SimulateTouchIdPromptFailure();
        GetResult denied = Get(&store, uv, only);
        Check(denied.status == GetAssertionStatus::kUserConsentDenied &&
                  denied.responses.empty(),
              what + ": " + where + " asks first; cancel signs nothing");
        env.SimulateTouchIdPromptSuccess();
        GetResult got = Get(&store, uv, only);
        bool uv_set = got.status == GetAssertionStatus::kSuccess &&
                      !got.responses.empty();
        for (const auto& response : got.responses) {
          uv_set = uv_set &&
                   response.authenticator_data.obtained_user_verification();
        }
        Check(uv_set, what + ": " + where + " signs with UV flag set");
      }
    }
  }
  base::ThreadPoolInstance::Get()->Shutdown();
  std::cout << (g_failures ? "FAIL: " : "PASS: ") << g_failures << " failed" << std::endl;
  return g_failures ? 1 : 0;
}

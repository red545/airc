// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

// The "Airc Safe Storage" key (engine patch 041). Stock Chromium makes a new
// key whenever its keychain lookup says "not found" (and replaces an existing
// item through KeychainV2::AddGenericPassword's add-or-update), and goes on
// with no key at all when the lookup fails. Either way the passwords and
// cookies saved under the old key can be lost. Airc instead:
//   - creates a key only when the item is missing AND the data dir holds no
//     profile data (a first run), and only with add-if-absent;
//   - never replaces, overwrites or deletes an item that exists;
//   - refuses a key that doesn't match the key check written when the data was
//     first locked with it (a different key: case (d));
//   - otherwise asks: Try Again, Continue Without Saved Passwords for Now (no
//     key this launch: nothing is decrypted, encrypted, deleted or re-encrypted)
//     or Quit; it asks again on the next launch.
// Test seams (--airc-test, scratch data dirs only): keychain=file (a file in
// the data dir), keychain=scratch (<airc data dir>/Scratch.keychain-db, never
// the search list; keychainPassword unlocks it, keychainLock=1 locks it),
// keychainFail, keychainHiddenReads, safeStorageAnswer.

#include "airc/core/airc_safe_storage.h"

#import <AppKit/AppKit.h>
#include <Security/Security.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <initializer_list>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/apple/bridging.h"
#include "base/apple/foundation_util.h"
#include "base/apple/scoped_cftyperef.h"
#include "base/base64.h"
#include "base/command_line.h"
#include "base/containers/span.h"
#include "base/files/file_enumerator.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/files/scoped_file.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "base/process/process.h"
#include "base/rand_util.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/strings/sys_string_conversions.h"
#include "base/synchronization/lock.h"
#include "base/task/single_thread_task_runner.h"
#include "chrome/common/chrome_constants.h"
#include "chrome/common/chrome_switches.h"
#include "components/password_manager/core/browser/password_manager_constants.h"
#include "components/webdata/common/webdata_constants.h"
#include "crypto/apple/keychain_util.h"
#include "crypto/apple/keychain_v2.h"
#include "crypto/hmac.h"
#include "airc/core/airc_content_hooks.h"
#include "airc/core/airc_launch_switches.h"

namespace airc {

namespace {

bool g_fresh_user_data_dir = false;
// The person chose "Start Over with a New Key" (missing item) or "Use This Key
// from Now On" (a key that doesn't match): one-shot, read on the worker thread.
std::atomic<bool> g_start_over_requested{false};
std::atomic<bool> g_accept_current_key{false};

base::FilePath& UserDataDir() {
  static base::NoDestructor<base::FilePath> dir;
  return *dir;
}

constexpr char kKeyCheckName[] = "Airc Safe Storage Check";
constexpr char kKeyCheckLabel[] = "Airc Safe Storage key check v1";
constexpr char kTestLogName[] = "Test Safe Storage Log";

// Test runs only: a line for the check (the file keychain's log).
void TestNote(std::string_view what) {
  if (!TestInstance() || UserDataDir().empty()) {
    return;
  }
  static base::NoDestructor<base::Lock> lock;
  base::AutoLock hold(*lock);
  const base::FilePath log = UserDataDir().Append(kTestLogName);
  const std::string line = std::string(what) + "\n";
  if (!base::AppendToFile(log, line)) {
    base::WriteFile(log, line);
  }
}

enum class Presence { kAbsent, kPresent, kUnknown };

Presence ProbeOne(const base::FilePath& path) {
  struct stat info;
  if (lstat(path.value().c_str(), &info) != 0) {
    return errno == ENOENT ? Presence::kAbsent : Presence::kUnknown;
  }
  if (stat(path.value().c_str(), &info) != 0) {
    return Presence::kUnknown;
  }
  return Presence::kPresent;
}

struct Marker {
  base::FilePath::StringViewType dir;
  base::FilePath::StringViewType name;
};

Presence Probe(const base::FilePath& root, const Marker& marker) {
  base::FilePath path = root;
  for (base::FilePath::StringViewType part : {marker.dir, marker.name}) {
    if (part.empty()) {
      continue;
    }
    path = path.Append(part);
    const Presence presence = ProbeOne(path);
    if (presence != Presence::kPresent) {
      return presence;
    }
  }
  return Presence::kPresent;
}

bool SurelyHoldsNoProfileData(const base::FilePath& profile) {
  const Marker markers[] = {
      {{}, chrome::kPreferencesFilename},
      {{}, chrome::kCookieFilename},
      {chrome::kNetworkDataDirname, chrome::kCookieFilename},
      {{}, password_manager::kLoginDataForProfileFileName},
      {{}, password_manager::kLoginDataForAccountFileName},
      {{}, kWebDataFilename},
  };
  for (const Marker& marker : markers) {
    if (Probe(profile, marker) != Presence::kAbsent) {
      return false;
    }
  }
  return true;
}

bool IsFreshUserDataDir(const base::FilePath& dir) {
  if (dir.empty()) {
    return false;
  }
  switch (ProbeOne(dir)) {
    case Presence::kAbsent:
      return true;
    case Presence::kUnknown:
      return false;
    case Presence::kPresent:
      break;
  }
  if (Probe(dir, {{}, chrome::kLocalStateFilename}) != Presence::kAbsent) {
    return false;
  }
  base::FileEnumerator entries(
      dir, false, base::FileEnumerator::NAMES_ONLY, FILE_PATH_LITERAL(""),
      base::FileEnumerator::FolderSearchPolicy::MATCH_ONLY,
      base::FileEnumerator::ErrorPolicy::STOP_ENUMERATION);
  for (base::FilePath entry = entries.Next(); !entry.empty();
       entry = entries.Next()) {
    struct stat info;
    if (stat(entry.value().c_str(), &info) != 0) {
      if (errno != ENOENT) {
        return false;
      }
      if (ProbeOne(entry) != Presence::kAbsent) {
        return false;
      }
      continue;
    }
    if (S_ISDIR(info.st_mode) && !SurelyHoldsNoProfileData(entry)) {
      return false;
    }
  }
  const base::File::Error error = entries.GetError();
  return error == base::File::FILE_OK ||
         error == base::File::FILE_ERROR_NOT_FOUND;
}


// --- Key check: which key the saved data was locked with -------------------

std::string KeyCheckFor(const std::string& password) {
  const auto mac = crypto::hmac::SignSha256(base::as_byte_span(password),
                                            base::as_byte_span(std::string_view(kKeyCheckLabel)));
  return "v1 " + base::HexEncode(mac) + "\n";
}

enum class KeyCheck { kMatches, kAbsent, kDiffers, kUnreadable };

KeyCheck CompareKeyCheck(const std::string& password) {
  if (UserDataDir().empty()) {
    return KeyCheck::kUnreadable;
  }
  const base::FilePath path = UserDataDir().Append(kKeyCheckName);
  std::string saved;
  if (!base::ReadFileToStringWithMaxSize(path, &saved, 4096)) {
    return ProbeOne(path) == Presence::kAbsent ? KeyCheck::kAbsent
                                               : KeyCheck::kUnreadable;
  }
  return saved == KeyCheckFor(password) ? KeyCheck::kMatches
                                        : KeyCheck::kDiffers;
}

void WriteKeyCheck(const std::string& password) {
  if (UserDataDir().empty() || !base::DirectoryExists(UserDataDir())) {
    return;
  }
  if (!base::ImportantFileWriter::WriteFileAtomically(
          UserDataDir().Append(kKeyCheckName), KeyCheckFor(password))) {
    LOG(ERROR) << "[airc] Safe Storage key check: couldn't write";
  }
}

// --- Test keychains ---------------------------------------------------------

// keychain=file: the key is a file in the data dir. Only add-if-absent writes
// it; every other write is refused, so a check sees any attempt in the log.
class FileKeychain : public crypto::apple::KeychainV2 {
 public:
  FileKeychain(base::FilePath secret, int hidden_reads, OSStatus failure)
      : secret_(std::move(secret)),
        hidden_reads_(hidden_reads),
        failure_(failure) {}

  base::expected<std::vector<uint8_t>, OSStatus> FindGenericPassword(
      std::string_view service_name,
      std::string_view account_name) override {
    if (failure_ != noErr) {
      TestNote("find failed " + base::NumberToString(failure_));
      return base::unexpected(failure_);
    }
    if (hidden_reads_ > 0) {
      --hidden_reads_;
      TestNote("find hidden");
      return base::unexpected(errSecItemNotFound);
    }
    std::optional<std::vector<uint8_t>> bytes = base::ReadFileToBytes(secret_);
    if (!bytes) {
      TestNote("find missing");
      return base::unexpected(errSecItemNotFound);
    }
    TestNote(bytes->empty() ? "find empty" : "find found");
    return std::move(*bytes);
  }

  OSStatus ItemAdd(CFDictionaryRef attributes, CFTypeRef* result) override {
    NSData* data = base::apple::ObjCCast<NSData>(
        base::apple::CFToNSPtrCast(attributes)[base::apple::CFToNSPtrCast(kSecValueData)]);
    if (!data.length) {
      TestNote("add failed");
      return errSecParam;
    }
    base::ScopedFD fd(
        open(secret_.value().c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600));
    if (!fd.is_valid()) {
      const bool exists = errno == EEXIST;
      TestNote(exists ? "add duplicate" : "add failed");
      return exists ? errSecDuplicateItem : errSecIO;
    }
    if (!base::WriteFileDescriptor(fd.get(), base::apple::NSDataToSpan(data))) {
      TestNote("add failed");
      return errSecIO;
    }
    TestNote("add created");
    return noErr;
  }

  OSStatus AddGenericPassword(std::string_view service_name,
                              std::string_view account_name,
                              base::span<const uint8_t> password) override {
    TestNote("add-or-update refused");
    return errSecUnimplemented;
  }

  OSStatus ItemCopyMatching(CFDictionaryRef query, CFTypeRef* result) override {
    TestNote("item copy refused");
    return errSecUnimplemented;
  }

  OSStatus ItemDelete(CFDictionaryRef query) override {
    TestNote("item delete refused");
    return errSecUnimplemented;
  }

  OSStatus ItemUpdate(CFDictionaryRef query,
                      CFDictionaryRef keychain_data) override {
    TestNote("item update refused");
    return errSecUnimplemented;
  }

 private:
  const base::FilePath secret_;
  int hidden_reads_;
  const OSStatus failure_;
};

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// keychain=scratch: a real (legacy file) keychain at <airc data dir>/
// Scratch.keychain-db that a check made, opened by path and never put on the
// search list. Never asks: a read that would ask fails, as a denied one does.
class ScratchKeychain : public crypto::apple::KeychainV2 {
 public:
  explicit ScratchKeychain(const base::FilePath& path) {
    const OSStatus status =
        SecKeychainOpen(path.value().c_str(), keychain_.InitializeInto());
    TestNote("scratch open " + base::NumberToString(status));
    // Lock state is per login session: the check's `security` (over ssh) can't
    // unlock or lock it for this app, so the app does, as arcimport3's does.
    if (const std::optional<std::string> password =
            TestValue("keychainPassword");
        keychain_ && password) {
      const OSStatus unlocked = SecKeychainUnlock(
          keychain_.get(), static_cast<UInt32>(password->size()),
          password->data(), true);
      TestNote("scratch unlock " + base::NumberToString(unlocked));
    }
    if (keychain_ && TestFlag("keychainLock")) {
      TestNote("scratch lock " +
               base::NumberToString(SecKeychainLock(keychain_.get())));
    }
  }

  base::expected<std::vector<uint8_t>, OSStatus> FindGenericPassword(
      std::string_view service_name,
      std::string_view account_name) override {
    if (!keychain_) {
      return base::unexpected(errSecNoSuchKeychain);
    }
    // A read of a locked legacy keychain shows macOS's unlock dialog even with
    // interaction off: a check never reads one, it answers as macOS does
    // without the dialog.
    SecKeychainStatus keychain_status = 0;
    if (SecKeychainGetStatus(keychain_.get(), &keychain_status) != noErr ||
        !(keychain_status & kSecUnlockStateStatus)) {
      TestNote("scratch find locked");
      return base::unexpected(errSecInteractionNotAllowed);
    }
    NSDictionary* query = @{
      base::apple::CFToNSPtrCast(kSecClass) :
          base::apple::CFToNSPtrCast(kSecClassGenericPassword),
      base::apple::CFToNSPtrCast(kSecAttrService) :
          base::SysUTF8ToNSString(service_name),
      base::apple::CFToNSPtrCast(kSecAttrAccount) :
          base::SysUTF8ToNSString(account_name),
      base::apple::CFToNSPtrCast(kSecMatchLimit) :
          base::apple::CFToNSPtrCast(kSecMatchLimitOne),
      base::apple::CFToNSPtrCast(kSecReturnData) : @YES,
      base::apple::CFToNSPtrCast(kSecMatchSearchList) :
          @[ (__bridge id)keychain_.get() ],
      base::apple::CFToNSPtrCast(kSecUseAuthenticationUI) :
          base::apple::CFToNSPtrCast(kSecUseAuthenticationUIFail),
    };
    base::apple::ScopedCFTypeRef<CFTypeRef> result;
    // Test runs only: what would ask fails instead (as SafeStorageKey.swift's
    // silent read does), so no macOS prompt ever shows.
    Boolean allowed = true;
    SecKeychainGetUserInteractionAllowed(&allowed);
    SecKeychainSetUserInteractionAllowed(false);
    const OSStatus status = SecItemCopyMatching(
        base::apple::NSToCFPtrCast(query), result.InitializeInto());
    SecKeychainSetUserInteractionAllowed(allowed);
    if (status != noErr) {
      TestNote("scratch find " + base::NumberToString(status));
      return base::unexpected(status);
    }
    NSData* data = base::apple::ObjCCast<NSData>(
        (__bridge id)result.get());
    TestNote(data.length ? "scratch find found" : "scratch find empty");
    const base::span<const uint8_t> bytes = base::apple::NSDataToSpan(data);
    return std::vector<uint8_t>(bytes.begin(), bytes.end());
  }

  OSStatus ItemAdd(CFDictionaryRef attributes, CFTypeRef* result) override {
    NSMutableDictionary* add =
        [base::apple::CFToNSPtrCast(attributes) mutableCopy];
    add[base::apple::CFToNSPtrCast(kSecUseKeychain)] =
        (__bridge id)keychain_.get();
    const OSStatus status =
        SecItemAdd(base::apple::NSToCFPtrCast(add), result);
    TestNote("scratch add " + base::NumberToString(status));
    return status;
  }

  OSStatus AddGenericPassword(std::string_view service_name,
                              std::string_view account_name,
                              base::span<const uint8_t> password) override {
    TestNote("add-or-update refused");
    return errSecUnimplemented;
  }
  OSStatus ItemCopyMatching(CFDictionaryRef query, CFTypeRef* result) override {
    TestNote("item copy refused");
    return errSecUnimplemented;
  }
  OSStatus ItemDelete(CFDictionaryRef query) override {
    TestNote("item delete refused");
    return errSecUnimplemented;
  }
  OSStatus ItemUpdate(CFDictionaryRef query,
                      CFDictionaryRef keychain_data) override {
    TestNote("item update refused");
    return errSecUnimplemented;
  }

 private:
  base::apple::ScopedCFTypeRef<SecKeychainRef> keychain_;
};
#pragma clang diagnostic pop

crypto::apple::KeychainV2* TestKeychain() {
  if (TestValue("keychain") == "scratch") {
    static base::NoDestructor<ScratchKeychain> scratch(
        UserDataDir().DirName().Append("Scratch.keychain-db"));
    return scratch.get();
  }
  int hidden_reads = 0;
  if (const std::optional<std::string> hide =
          TestValue("keychainHiddenReads")) {
    base::StringToInt(*hide, &hidden_reads);
  }
  const std::optional<std::string> fail = TestValue("keychainFail");
  OSStatus failure = noErr;
  const std::pair<const char*, OSStatus> failures[] = {
      {"decode", errSecDecode},
      {"denied", errSecAuthFailed},
      {"canceled", errSecUserCanceled},
      {"locked", errSecInteractionNotAllowed},
      {"interaction", errSecInteractionRequired},
      {"entitlement", errSecMissingEntitlement},
      {"io", errSecIO},
  };
  for (const auto& [name, status] : failures) {
    if (fail == name) {
      failure = status;
    }
  }
  static base::NoDestructor<FileKeychain> keychain(
      UserDataDir().Append("Test Safe Storage Key"), hidden_reads, failure);
  return keychain.get();
}

// --- Reading the key (worker thread) ------------------------------------------

// Add-if-absent, with the attributes Chromium's own create uses. SecItemAdd
// fails with errSecDuplicateItem when the item exists: it never updates one.
OSStatus AddKeyIfAbsent(crypto::apple::KeychainV2* keychain,
                        std::string_view service,
                        std::string_view account,
                        const std::string& password) {
  NSDictionary* attributes = @{
    base::apple::CFToNSPtrCast(kSecValueData) :
        [NSData dataWithBytes:password.data() length:password.size()],
    base::apple::CFToNSPtrCast(kSecClass) :
        base::apple::CFToNSPtrCast(kSecClassGenericPassword),
    base::apple::CFToNSPtrCast(kSecAttrAccessible) :
        base::apple::CFToNSPtrCast(
            crypto::apple::GetKeychainAccessibilityAttribute()),
    base::apple::CFToNSPtrCast(kSecAttrService) :
        base::SysUTF8ToNSString(service),
    base::apple::CFToNSPtrCast(kSecAttrAccount) :
        base::SysUTF8ToNSString(account),
  };
  return keychain->ItemAdd(base::apple::NSToCFPtrCast(attributes), nullptr);
}

int ReadKey(crypto::apple::KeychainV2* keychain,
            std::string_view service,
            std::string_view account,
            std::string* password) {
  base::expected<std::vector<uint8_t>, OSStatus> found =
      keychain->FindGenericPassword(service, account);
  bool created = false;
  if (!found.has_value()) {
    if (found.error() != errSecItemNotFound) {
      LOG(ERROR) << "[airc] Safe Storage key unreadable (" << found.error()
                 << "): not replacing it";
      TestNote("read unreadable " + base::NumberToString(found.error()));
      return found.error();
    }
    const bool may_create =
        g_fresh_user_data_dir || g_start_over_requested.exchange(false);
    if (!may_create) {
      LOG(ERROR) << "[airc] Safe Storage key not found, but this data dir "
                    "holds saved data: not making a new key";
      TestNote("read missing, data exists: not creating");
      return errSecItemNotFound;
    }
    const std::string fresh =
        base::Base64Encode(base::RandBytesAsVector(128 / 8));
    const OSStatus added = AddKeyIfAbsent(keychain, service, account, fresh);
    if (added == noErr) {
      *password = fresh;
      created = true;
      g_fresh_user_data_dir = false;
      TestNote("read created");
    } else {
      // errSecDuplicateItem: it appeared meanwhile (another launch made it);
      // read that one, never replace it.
      LOG(ERROR) << "[airc] Safe Storage key: add-if-absent " << added;
      found = keychain->FindGenericPassword(service, account);
      if (!found.has_value()) {
        TestNote("read add failed " + base::NumberToString(added));
        return added == errSecDuplicateItem ? found.error() : added;
      }
    }
  }
  if (!created) {
    if (found->empty()) {
      TestNote("read empty");
      return errSecDecode;
    }
    password->assign(found->begin(), found->end());
  }
  switch (CompareKeyCheck(*password)) {
    case KeyCheck::kMatches:
      TestNote("read ok");
      break;
    case KeyCheck::kAbsent:
      WriteKeyCheck(*password);
      TestNote("read ok, key check written");
      break;
    case KeyCheck::kUnreadable:
      LOG(ERROR) << "[airc] Safe Storage key check unreadable: not enforced";
      TestNote("read ok, key check unreadable");
      break;
    case KeyCheck::kDiffers:
      if (g_accept_current_key.exchange(false)) {
        WriteKeyCheck(*password);
        TestNote("read ok, key accepted by the person");
        break;
      }
      LOG(ERROR) << "[airc] Safe Storage key differs from the saved data's: "
                    "not using it";
      TestNote("read wrong key");
      password->clear();
      return kAircSafeStorageWrongKey;
  }
  return noErr;
}

// --- Asking (UI thread) ---------------------------------------------------------

enum class KeyProblem {
  kMissing,
  kLocked,
  kWrongKey,
  kEntitlement,
  kDamaged,
  kOther
};

KeyProblem Classify(int status) {
  switch (status) {
    case errSecItemNotFound:
      return KeyProblem::kMissing;
    case kAircSafeStorageWrongKey:
      return KeyProblem::kWrongKey;
    case errSecAuthFailed:
    case errSecUserCanceled:
    case errSecInteractionNotAllowed:
    case errSecInteractionRequired:
    case errSecNoAccessForItem:
    case errSecNotAvailable:
      return KeyProblem::kLocked;
    case errSecMissingEntitlement:
      return KeyProblem::kEntitlement;
    case errSecDecode:
      return KeyProblem::kDamaged;
    default:
      return KeyProblem::kOther;
  }
}

const char* ProblemName(KeyProblem problem) {
  switch (problem) {
    case KeyProblem::kMissing: return "missing";
    case KeyProblem::kLocked: return "locked";
    case KeyProblem::kWrongKey: return "wrong-key";
    case KeyProblem::kEntitlement: return "entitlement";
    case KeyProblem::kDamaged: return "damaged";
    case KeyProblem::kOther: return "other";
  }
}

NSString* const kTryAgain = @"Try Again";
NSString* const kContinue = @"Continue Without Saved Passwords for Now";
NSString* const kQuit = @"Quit";
NSString* const kStartOver = @"Start Over with a New Key";
NSString* const kUseThisKey = @"Use This Key from Now On";

NSString* const kSafeNote =
    @"\n\nNothing is deleted or replaced. If you continue without them, Airc "
    @"doesn’t save or change passwords and cookies until the next "
    @"launch, and asks again then.";

NSAlert* MakeAlert(KeyProblem problem) {
  NSAlert* alert = [[NSAlert alloc] init];
  alert.alertStyle = NSAlertStyleWarning;
  NSString* body = nil;
  switch (problem) {
    case KeyProblem::kLocked:
      alert.messageText = @"Airc can’t open your saved passwords.";
      body = @"Your saved passwords and cookies are safe. They’re locked "
             @"with a key in your login keychain, and Airc isn’t allowed "
             @"to open it right now. Unlock your login keychain, or allow "
             @"Airc to use “Airc Safe Storage” when macOS asks (or "
             @"in Keychain Access), then choose Try Again. You can also quit "
             @"and open Airc again.";
      break;
    case KeyProblem::kMissing:
      alert.messageText = @"Airc can’t find the key to your saved "
                          @"passwords.";
      body = @"Your saved passwords and cookies are locked with "
             @"“Airc Safe Storage”, and your keychain doesn’t "
             @"have it right now. If you switched or restored your login "
             @"keychain, put the item back, then choose Try Again. A new key "
             @"can never open what you saved, so Airc only makes one if you "
             @"choose Start Over.";
      break;
    case KeyProblem::kWrongKey:
      alert.messageText = @"The key in your keychain doesn’t match your "
                          @"saved passwords.";
      body = @"“Airc Safe Storage” in your login keychain isn’t "
             @"the key your saved passwords and cookies were locked with, so "
             @"Airc won’t use it. Put the previous key back (for example "
             @"from a keychain backup), then choose Try Again.";
      break;
    case KeyProblem::kEntitlement:
      alert.messageText = @"This copy of Airc can’t use your keychain.";
      body = @"Your saved passwords and cookies are locked with a key in your "
             @"login keychain, and this copy of Airc isn’t allowed to "
             @"open it. Reinstall Airc from aircbrowser.com, then open it "
             @"again.";
      break;
    case KeyProblem::kDamaged:
      alert.messageText = @"Airc can’t read the key to your saved "
                          @"passwords.";
      body = @"Your saved passwords and cookies are locked with "
             @"“Airc Safe Storage” in your login keychain, and "
             @"macOS says that item is damaged. Restore your login keychain "
             @"from a backup, then choose Try Again.";
      break;
    case KeyProblem::kOther:
      alert.messageText = @"Airc can’t open your saved passwords right "
                          @"now.";
      body = @"Your saved passwords and cookies are locked with a key in your "
             @"login keychain, and macOS couldn’t give it to Airc just "
             @"now. Choose Try Again, or quit and open Airc again.";
      break;
  }
  alert.informativeText = [body stringByAppendingString:kSafeNote];
  [alert addButtonWithTitle:kTryAgain];
  [alert addButtonWithTitle:kContinue];
  [alert addButtonWithTitle:kQuit];
  if (problem == KeyProblem::kMissing || problem == KeyProblem::kWrongKey) {
    NSButton* destructive = [alert addButtonWithTitle:problem ==
                                    KeyProblem::kMissing ? kStartOver
                                                         : kUseThisKey];
    destructive.hasDestructiveAction = YES;
  }
  return alert;
}

// Test runs: answers come from safeStorageAnswer=a+b+c, one per question (the
// last one repeats). The alert still runs modally; the answer clicks its
// button, after the alert window's picture is saved next to the test log.
std::optional<std::string> NextTestAnswer() {
  static int asked = 0;
  const std::optional<std::string> list = TestValue("safeStorageAnswer");
  if (!list || UserDataDir().empty()) {
    return std::nullopt;
  }
  const std::vector<std::string> answers = base::SplitString(
      *list, "+", base::TRIM_WHITESPACE, base::SPLIT_WANT_NONEMPTY);
  if (answers.empty()) {
    return std::nullopt;
  }
  const size_t index = std::min<size_t>(asked++, answers.size() - 1);
  return answers[index];
}

void SaveAlertPicture(NSAlert* alert, int number) {
  NSView* view = alert.window.contentView;
  NSBitmapImageRep* bitmap =
      [view bitmapImageRepForCachingDisplayInRect:view.bounds];
  if (!bitmap) {
    return;
  }
  [view cacheDisplayInRect:view.bounds toBitmapImageRep:bitmap];
  NSData* png = [bitmap representationUsingType:NSBitmapImageFileTypePNG
                                     properties:@{}];
  const base::FilePath path = UserDataDir().Append(
      "Test Safe Storage Alert " + base::NumberToString(number) + ".png");
  [png writeToFile:base::apple::FilePathToNSString(path) atomically:YES];
}

void AskAboutKey(int status, base::OnceCallback<void(bool)> answer) {
  static int asked = 0;
  const int number = ++asked;
  const KeyProblem problem = Classify(status);
  NSAlert* alert = MakeAlert(problem);
  std::string buttons;
  for (NSButton* button in alert.buttons) {
    buttons += (buttons.empty() ? "" : " | ") +
               base::SysNSStringToUTF8(button.title);
  }
  LOG(ERROR) << "[airc] Safe Storage key unreadable (" << status << ", "
             << ProblemName(problem) << "): asking";
  TestNote(std::string("alert ") + ProblemName(problem) + " " +
           base::NumberToString(status) + ": " +
           base::SysNSStringToUTF8(alert.messageText) + " || " +
           base::SysNSStringToUTF8(alert.informativeText) + " || " + buttons);
  if (const std::optional<std::string> test = NextTestAnswer()) {
    NSString* title = *test == "retry"        ? kTryAgain
                      : *test == "continue"   ? kContinue
                      : *test == "start-over" ? kStartOver
                      : *test == "use-key"    ? kUseThisKey
                                              : kQuit;
    NSTimer* timer = [NSTimer
        timerWithTimeInterval:0.6
                      repeats:NO
                        block:^(NSTimer*) {
                          SaveAlertPicture(alert, number);
                          for (NSButton* button in alert.buttons) {
                            if ([button.title isEqualToString:title]) {
                              [button performClick:nil];
                              return;
                            }
                          }
                          [NSApp stopModalWithCode:NSAlertThirdButtonReturn];
                        }];
    [NSRunLoop.currentRunLoop addTimer:timer forMode:NSModalPanelRunLoopMode];
  }
  const NSModalResponse response = [alert runModal];
  const NSInteger index = response - NSAlertFirstButtonReturn;
  NSString* chosen =
      index >= 0 && index < static_cast<NSInteger>(alert.buttons.count)
          ? alert.buttons[index].title
          : kQuit;
  TestNote("answer " + base::SysNSStringToUTF8(chosen));
  LOG(ERROR) << "[airc] Safe Storage key unreadable: "
             << base::SysNSStringToUTF8(chosen);
  if ([chosen isEqualToString:kTryAgain]) {
    std::move(answer).Run(true);
  } else if ([chosen isEqualToString:kContinue]) {
    std::move(answer).Run(false);
  } else if ([chosen isEqualToString:kStartOver]) {
    g_start_over_requested = true;
    std::move(answer).Run(true);
  } else if ([chosen isEqualToString:kUseThisKey]) {
    g_accept_current_key = true;
    std::move(answer).Run(true);
  } else {
    base::Process::TerminateCurrentProcessImmediately(EXIT_FAILURE);
  }
}

void SafeStorageUnreadable(int status, base::OnceCallback<void(bool)> answer) {
  base::SingleThreadTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&AskAboutKey, status, std::move(answer)));
}

}  // namespace

void GuardSafeStorageKey(const base::CommandLine& command_line) {
  const base::FilePath dir =
      command_line.GetSwitchValuePath(switches::kUserDataDir);
  UserDataDir() = dir;
  g_fresh_user_data_dir = IsFreshUserDataDir(dir);
  g_airc_safe_storage_read = &ReadKey;
  g_airc_safe_storage_unreadable = &SafeStorageUnreadable;
  const std::optional<std::string> keychain = TestValue("keychain");
  if (keychain == "file" || keychain == "scratch") {
    g_airc_test_keychain = &TestKeychain;
  }
}

}  // namespace airc

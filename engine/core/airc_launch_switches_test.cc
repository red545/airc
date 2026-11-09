// Copyright 2026 The Airc Authors
// SPDX-License-Identifier: Apache-2.0

// One fresh process per case: the production gate is intentionally immutable.
#include <cstdio>
#include <string>

#include "airc/core/airc_launch_switches.h"
#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/files/scoped_temp_dir.h"
#include "base/threading/scoped_blocking_call_internal.h"
#include "base/threading/thread_restrictions.h"
#include "chrome/common/chrome_switches.h"
#include "components/os_crypt/common/os_crypt_switches.h"
#include "content/public/common/content_switches.h"

namespace {

// ScopedDisallowBlocking catches regressions in DCHECK builds. This observer
// also detects realpath's ScopedBlockingCall in the release engine build.
class BlockingCounter : public base::internal::BlockingObserver {
 public:
  void BlockingStarted(base::BlockingType) override { ++calls; }
  void BlockingTypeUpgraded() override {}
  void BlockingEnded() override {}
  int calls = 0;
};

bool Expect(bool value, const char* message) {
  if (!value) {
    std::fprintf(stderr, "FAIL %s\n", message);
  }
  return value;
}

}  // namespace

int main(int argc, char** argv) {
  base::CommandLine::Init(argc, argv);
  auto& command = *base::CommandLine::ForCurrentProcess();
  const std::string scenario = command.GetSwitchValueASCII("case");
  base::ScopedTempDir temp;
  if (!temp.CreateUniqueTempDirUnderPath(
          command.GetSwitchValuePath("test-root"))) {
    return 1;
  }
  const auto scratch = temp.GetPath().Append("Scratch");
  const auto chromium = scratch.Append("Chromium");
  const auto other = temp.GetPath().Append("Other");
  if (!base::CreateDirectory(other)) {
    return 1;
  }
  const bool late_directory = scenario == "ordinary-new" ||
                              scenario == "early-missing";
  if (!late_directory && !base::CreateDirectory(chromium)) {
    return 1;
  }
  command.AppendSwitchPath(airc::kDataDirSwitch, scratch);
  command.AppendSwitchPath(switches::kUserDataDir, chromium);
  command.AppendSwitch(os_crypt::switches::kUseMockKeychain);
  const bool ordinary = scenario == "ordinary" || scenario == "ordinary-new";
  if (!ordinary) {
    command.AppendSwitchASCII(airc::kTestSwitch, "unpackedExtension,disabled=off");
    command.AppendSwitchASCII(airc::kTraceSwitch, "profileGate");
  }
  bool allowed = true;
  if (scenario == "missing-mock") {
    command.RemoveSwitch(os_crypt::switches::kUseMockKeychain);
    allowed = false;
  } else if (scenario == "missing-scratch") {
    command.RemoveSwitch(airc::kDataDirSwitch);
    allowed = false;
  } else if (scenario == "missing-user-data") {
    command.RemoveSwitch(switches::kUserDataDir);
    allowed = false;
  } else if (scenario == "mismatch") {
    command.AppendSwitchPath(switches::kUserDataDir, other);
    allowed = false;
  } else if (scenario == "helper") {
    command.AppendSwitchASCII(switches::kProcessType, "renderer");
    allowed = false;
  } else if (scenario == "symlink-match" || scenario == "symlink-mismatch") {
    const auto alias = temp.GetPath().Append("Alias");
    if (!base::CreateSymbolicLink(
            scenario == "symlink-match" ? chromium : other, alias)) {
      return 1;
    }
    command.AppendSwitchPath(switches::kUserDataDir, alias);
    allowed = scenario == "symlink-match";
  } else if (scenario == "early-missing") {
    allowed = false;
  } else if (scenario != "explicit" && !ordinary) {
    return 1;
  }

  BlockingCounter counter;
  base::internal::SetBlockingObserverForCurrentThread(&counter);
  bool ok = true;
  {
    base::ScopedDisallowBlocking no_blocking;
    ok &= Expect(!airc::TestInstance(), "uninitialized gate fails closed");
    ok &= Expect(!airc::TestFlag("unpackedExtension"), "early flag fails closed");
    ok &= Expect(!airc::Traced("profileGate"), "early trace fails closed");
  }
  ok &= Expect(counter.calls == 0, "early queries do no blocking I/O");
  // Match BasicStartupComplete, then PreSandboxStartup's directory creation.
  airc::DecideTestGateAtStartup();
  if (late_directory && !base::CreateDirectory(chromium)) {
    base::internal::ClearBlockingObserverForCurrentThread();
    return 1;
  }
  airc::InitializeTestGateAtStartup();
  // The old gate also cached forever. Moving the directory must not cause
  // another resolution or revise either an early refusal or an acceptance.
  if (!base::Move(scratch, temp.GetPath().Append("Moved"))) {
    base::internal::ClearBlockingObserverForCurrentThread();
    return 1;
  }
  ok &= Expect(!base::MakeAbsoluteFilePath(other).empty(), "observer fixture");
  ok &= Expect(counter.calls > 0, "observer detects blocking path resolution");
  counter.calls = 0;
  {
    base::ScopedDisallowBlocking no_blocking;
    airc::InitializeTestGateAtStartup();  // Idempotent, no further I/O.
    for (int i = 0; i < 3; ++i) {
      ok &= Expect(airc::TestInstance() == allowed, "cached decision");
      ok &= Expect(airc::TestFlag("unpackedExtension") == (allowed && !ordinary),
                   "test flag obeys gate");
      ok &= Expect(airc::Traced("profileGate") == (allowed && !ordinary),
                   "trace obeys gate");
      ok &= Expect(!airc::TestFlag("disabled"), "off flag stays off");
      ok &= Expect(!airc::TestValue("absent"), "unknown test is absent");
    }
  }
  base::internal::ClearBlockingObserverForCurrentThread();
  ok &= Expect(counter.calls == 0, "cached queries do no blocking I/O");
  std::printf("%s %s (query blocking calls: %d)\n", ok ? "PASS" : "FAIL",
              scenario.c_str(), counter.calls);
  return ok ? 0 : 1;
}

// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_LAUNCH_SWITCHES_H_
#define AIRC_CORE_AIRC_LAUNCH_SWITCHES_H_

#include <optional>
#include <string>
#include <string_view>

namespace base {
class CommandLine;
}

namespace airc {

inline constexpr char kBackgroundSwitch[] = "airc-background";
inline constexpr char kDataDirSwitch[] = "airc-data-dir";
inline constexpr char kTestSwitch[] = "airc-test";
inline constexpr char kTraceSwitch[] = "airc-trace";
inline constexpr char kSwitchesSwitch[] = "airc-switches";

bool BackgroundInstance();

std::optional<std::string> InstanceValue(std::string_view key);

bool SignedForDistribution();

bool TestInstance();

std::optional<std::string> TestValue(std::string_view key);

bool TestFlag(std::string_view key);

bool Traced(std::string_view area);

std::optional<bool> SwitchOverride(std::string_view name);

bool SwitchOn(std::string_view name);

bool ExperimentOn(std::string_view name);

void PassSwitchesToGpuProcess(base::CommandLine* gpu_command_line);

// Main startup thread only, while blocking is allowed. The decision is immutable
// thereafter; TestInstance/TestValue/TestFlag/Traced only read it.
void InitializeTestGateAtStartup();

// Keep explicit test/trace/background decisions before profile-gate processing.
void DecideTestGateAtStartup();

}

#endif

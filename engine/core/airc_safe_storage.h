// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_SAFE_STORAGE_H_
#define AIRC_CORE_AIRC_SAFE_STORAGE_H_

namespace base {
class CommandLine;
}

namespace airc {

void GuardSafeStorageKey(const base::CommandLine& command_line);

}

#endif

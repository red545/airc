// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_LIFETIME_H_
#define AIRC_CORE_AIRC_LIFETIME_H_

namespace airc {

void InstallAppOverrides();

void StartLifetimeObservers();

void QuitEngine();
bool IsQuitting();

void HostQuitCancelled();

}

#endif

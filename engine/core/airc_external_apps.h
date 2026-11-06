// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_EXTERNAL_APPS_H_
#define AIRC_CORE_AIRC_EXTERNAL_APPS_H_

#import <Foundation/Foundation.h>

#include <string>

namespace airc {

void InstallExternalAppPrompts();
void ResolveExternalApp(const std::string& request_id, bool open, bool remember);
NSArray<NSDictionary*>* TestExternalLaunches();
bool TestNoLaunch();
void RecordTestLaunch(NSDictionary* launch);

}

#endif

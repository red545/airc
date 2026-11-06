// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_API_INTERNAL_H_
#define AIRC_CORE_AIRC_API_INTERNAL_H_

#import "airc/core/public/Airc.h"

#include <string>

#include "base/functional/callback_forward.h"

class Profile;

namespace airc {

extern id<AircEngineDelegate> __strong g_delegate;
extern AircEngine* __strong g_engine;

NSString* NS(const std::string& s);
NSString* NS(const std::u16string& s);

void WhenProfileGone(Profile* profile, base::OnceClosure done);

}

#endif

// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_STRINGS_H_
#define AIRC_CORE_AIRC_STRINGS_H_

#include <string>

#include "ui/base/resource/resource_bundle.h"

namespace airc {

ui::ResourceBundle::Delegate* ProductStrings();

bool RenameProduct(std::u16string& text);

}

#endif

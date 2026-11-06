// Copyright 2026 The Airc Authors
// SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
#include "airc/core/airc_video_upscaling.h"
namespace airc {
void StartVideoUpscaling() {}
void SetVideoUpscalingEnabled(bool) {}
void SetVideoUpscalingTestConditions(std::optional<bool>, std::optional<bool>) {}
void VideoUpscalingInputsChanged() {}
NSDictionary* VideoUpscalingState() { return @{@"supported": @NO, @"enabled": @NO}; }
}

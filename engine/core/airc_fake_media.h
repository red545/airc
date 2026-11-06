// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_FAKE_MEDIA_H_
#define AIRC_CORE_AIRC_FAKE_MEDIA_H_

namespace content {
struct MediaStreamRequest;
}

namespace airc {

bool UsingFakeMediaDevices();

void InstallFakeMediaDevices();

void KeepAudioCaptureFake(content::MediaStreamRequest& request);

}

#endif

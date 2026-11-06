// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#ifndef AIRC_CORE_AIRC_MEMORY_H_
#define AIRC_CORE_AIRC_MEMORY_H_
namespace content { class WebContents; }
namespace airc {
void StartMemoryPolicy();
void StopMemoryPolicy();
void TrackTabMemory(content::WebContents* contents);
void MemoryHostVisibilityChanged(content::WebContents* contents);
bool DiscardSafely(content::WebContents* contents);
}
#endif

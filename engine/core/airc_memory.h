// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#ifndef AIRC_CORE_AIRC_MEMORY_H_
#define AIRC_CORE_AIRC_MEMORY_H_
namespace content { class WebContents; }
namespace airc {
void StartMemoryPolicy();
void StopMemoryPolicy();
void TrackTabMemory(content::WebContents* contents);
void MemoryHostVisibilityChanged(content::WebContents* contents);
// Accepts an asynchronous discard after native history-state acknowledgement.
// Navigation, showing the page or a new safety veto cancels it. A missed
// acknowledgement retries with backoff after thawing and rechecking protections.
// After three ACK timeouts or 60 seconds without completion, the last checkpoint is used if
// current native safety vetoes permit. Its age is not bounded for a hung page.
// Discarded state changes only when the native discard completes.
bool DiscardSafely(content::WebContents* contents);
}
#endif

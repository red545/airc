// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#ifndef AIRC_CORE_AIRC_PIP_WINDOW_HOOKS_H_
#define AIRC_CORE_AIRC_PIP_WINDOW_HOOKS_H_
@class NSWindow;
@class NSEvent;
// remote_cocoa must not depend on //airc/core. Installed on the UI thread.
inline bool (*g_airc_pip_window_event)(NSWindow*, NSEvent*) = nullptr;
inline bool (*g_airc_pip_nonactivating)(NSWindow*) = nullptr;
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#pragma once

/// Fatal signals of the browser process (CrashLog.c). The first call opens `record_dir/record` (the previous three
/// crashes kept as record.1 … record.3), lists the loaded binaries and installs the handlers; later calls install the
/// handlers again on top of whatever was installed since, chaining to it. `log_path` (dev and test builds only, else
/// NULL) also writes the human-readable Crash.log. `version`, `build` and `os_version` go into the record as they are.
void airc_crash_install(const char *record_dir, const char *log_path, const char *bundle_path, const char *version,
                        const char *build, const char *os_version);
/// 1 when every handled signal (SEGV, BUS, ILL, ABRT, TRAP, FPE) is ours right now.
int airc_crash_handlers_installed(void);
/// How many of those signals had someone else's handler before ours (Chromium's stack dumper), which ours hands on to.
int airc_crash_chained_handlers(void);
/// Binaries (Airc's and the system's) the record can name.
int airc_crash_image_count(void);

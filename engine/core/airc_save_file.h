// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#ifndef AIRC_CORE_AIRC_SAVE_FILE_H_
#define AIRC_CORE_AIRC_SAVE_FILE_H_

#include "content/browser/download/save_types.h"
namespace base { class FilePath; }
namespace content { class SaveFile; }
namespace airc {
// Download sequence. Propagate final rename failures to the matching package
// before SaveFileManager posts its unconditional Finish notification.
void RenameSaveFile(content::SaveFile* file, const base::FilePath& path,
                    int process_id, int frame_id, content::SavePackageId package_id);
}
#endif

// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#include "airc/core/airc_save_file.h"

#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/task/single_thread_task_runner.h"
#include "components/download/public/common/download_interrupt_reasons.h"
#include "content/browser/download/save_file.h"
#include "content/browser/download/save_package.h"
#include "content/browser/web_contents/web_contents_impl.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/render_frame_host.h"

namespace airc {
void RenameSaveFile(content::SaveFile* file, const base::FilePath& path,
                    int process_id, int frame_id, content::SavePackageId package_id) {
  if (file->Rename(path) == download::DOWNLOAD_INTERRUPT_REASON_NONE) return;
  // SaveFileManager already detached this temporary file and erases its map
  // entry after this call. Its destructor will not remove a failed rename.
  base::DeleteFile(file->FullPath());
  content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, base::BindOnce(
      [](int process_id, int frame_id, content::SavePackageId package_id) {
        auto* frame = content::RenderFrameHost::FromID(process_id, frame_id);
        if (!frame) return;
        auto* contents = static_cast<content::WebContentsImpl*>(
            content::WebContents::FromRenderFrameHost(frame));
        auto* package = contents ? contents->save_package() : nullptr;
        // Navigation or another save may already have replaced the package.
        if (package && package->id() == package_id && !package->finished())
          package->Cancel(/*user_action=*/false);
      }, process_id, frame_id, package_id));
}
}

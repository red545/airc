// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#include "airc/core/airc_page_script.h"

#include "base/no_destructor.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/render_process_host.h"
#include "ipc/ipc_channel_proxy.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "airc/core/mojom/airc.mojom.h"

namespace airc {

namespace {

std::string& Script() {
  static base::NoDestructor<std::string> script;
  return *script;
}

// The script one renderer process gets. A private (off-the-record) profile's
// processes get it wrapped so that install receives a third argument, true:
// its parts know at document start, before the page's own first script, that
// the document is private (Boosts stay off there, as Arc's did in Incognito).
// A render process belongs to one browser context, so this holds for every
// frame it runs; the page can't see or change it.
std::string ScriptFor(content::RenderProcessHost* host) {
  const std::string& script = Script();
  if (script.empty() || !host->GetBrowserContext() ||
      !host->GetBrowserContext()->IsOffTheRecord()) {
    return script;
  }
  return "(function (install) {\n"
         "  return typeof install !== 'function' ? install\n"
         "      : function (post, data) { return install(post, data, true); };\n"
         "})(\n" +
         script + "\n)";
}

}

void SetPageScript(const std::string& script) {
  Script() = script;
  for (auto it = content::RenderProcessHost::AllHostsIterator(); !it.IsAtEnd();
       it.Advance()) {
    content::RenderProcessHost* host = it.GetCurrentValue();
    if (host->IsInitializedAndNotDead()) {
      SendPageScript(host);
    }
  }
}

const std::string& GetPageScript() {
  return Script();
}

void SendPageScript(content::RenderProcessHost* host) {
  IPC::ChannelProxy* channel = host->GetChannel();
  if (!channel) {
    return;
  }
  mojo::AssociatedRemote<mojom::AircRendererConfig> config;
  channel->GetRemoteAssociatedInterface(&config);
  config->SetPageScript(ScriptFor(host));
}

}

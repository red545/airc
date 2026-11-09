// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#ifndef AIRC_CORE_AIRC_BLOCKING_H_
#define AIRC_CORE_AIRC_BLOCKING_H_
#include "content/public/browser/content_browser_client.h"
namespace network { class URLLoaderFactoryBuilder; }
namespace net { class IsolationInfo; }
namespace airc {
void ObserveBlockingPage(content::WebContents*);
void AppendBlockingFactory(content::BrowserContext*, content::RenderFrameHost*,
    content::ContentBrowserClient::URLLoaderFactoryType, const url::Origin&,
    const net::IsolationInfo&, network::URLLoaderFactoryBuilder&);
bool BlockWebSocket(content::RenderFrameHost*, const GURL&);
}
#endif

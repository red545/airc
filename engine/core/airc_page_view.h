// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_PAGE_VIEW_H_
#define AIRC_CORE_AIRC_PAGE_VIEW_H_

#import <Cocoa/Cocoa.h>

@protocol RenderWidgetHostViewMacDelegate;

namespace content {
class RenderWidgetHost;
}

namespace airc {

NSObject<RenderWidgetHostViewMacDelegate>* CreatePageViewDelegate(
    content::RenderWidgetHost* host);

}

#endif

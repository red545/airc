// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_TAB_INTERNAL_H_
#define AIRC_CORE_AIRC_TAB_INTERNAL_H_

#import <AppKit/AppKit.h>

#import "airc/core/public/Airc.h"
#include "base/memory/raw_ptr.h"

namespace content {
class WebContents;
}

@interface AircTab () {
  raw_ptr<content::WebContents> _contents;
  int _browserId;
  BOOL _independentZoom;
  NSColor* __strong _pageBackgroundColor;
}
@end

#endif

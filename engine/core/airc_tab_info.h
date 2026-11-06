// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_TAB_INFO_H_
#define AIRC_CORE_AIRC_TAB_INFO_H_

#import <Foundation/Foundation.h>

#include <string>

class GURL;

namespace content {
class WebContents;
}

namespace airc {

NSDictionary* SecurityInfoFor(content::WebContents* contents);

NSString* OriginOf(const GURL& url);

}

#endif

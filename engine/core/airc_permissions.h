// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_PERMISSIONS_H_
#define AIRC_CORE_AIRC_PERMISSIONS_H_

#import <Foundation/Foundation.h>

#include <string>

namespace content {
class WebContents;
}

namespace airc {

void InstallPermissionPrompts();

void ResolvePermission(const std::string& request_id,
                       const std::string& result,
                       bool remember);

void HostPermissionRequest(content::WebContents* contents, NSDictionary* request);
void HostPermissionRequestDismissed(NSString* request_id);

}

#endif

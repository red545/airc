// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_PASSWORD_PROMPT_H_
#define AIRC_CORE_AIRC_PASSWORD_PROMPT_H_

#import <Foundation/Foundation.h>

namespace content {
class WebContents;
}

namespace airc {

NSDictionary<NSString*, id>* PasswordPrompt(content::WebContents* contents);

void PasswordPromptShown(content::WebContents* contents);
void PasswordConfirmationShown(content::WebContents* contents);

void ResolvePasswordPrompt(content::WebContents* contents,
                           NSString* action,
                           NSString* username,
                           NSString* password);

}

#endif

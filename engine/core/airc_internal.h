// Copyright 2026 Mantra Patel
// SPDX-License-Identifier: Apache-2.0
// Modified by The Airc Authors

#ifndef AIRC_CORE_AIRC_INTERNAL_H_
#define AIRC_CORE_AIRC_INTERNAL_H_

#import "airc/core/public/Airc.h"

class Profile;

namespace content {
class WebContents;
}

namespace airc {
class WindowHost;

void NoteProfileDying(Profile* profile);
bool IsProfileDying(const Profile* profile);
void NoteProfileDeleting(Profile* profile);
bool IsProfileDeleting(const Profile* profile);
}

@interface AircProfile ()
+ (AircProfile*)wrapperFor:(Profile*)profile;
@property(readonly) Profile* chromeProfile;
@end

@interface AircTab ()
- (instancetype)initWithContents:(content::WebContents*)contents;
@property(readonly) content::WebContents* contents;
- (void)contentsDestroyed;
- (void)notify:(SEL)selector;
@end

@interface AircWindow ()
@property(readonly) airc::WindowHost* host;
@end

#endif

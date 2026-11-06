// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Included inside Host. Only owned windows; no global input or application activation.
- (void)pipLater:(int)step attempt:(int)attempt {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    [self pipStep:step attempt:attempt];
  });
}
- (void)pipStep:(int)step attempt:(int)attempt {
  AircTab* tab = self.tabs[0];
  NSDictionary* session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
  if (!session || [session[@"CGSSessionScreenIsLocked"] boolValue] || NSApp.active) {
    [tab exitPictureInPicture]; [self finish:@"locked or active; PiP test stopped"]; return;
  }
  if (attempt > 25) {
    [tab exitPictureInPicture]; [self finish:@"PiP transition timed out"]; return;
  }
  NSString* mode = Flag(@"--airc-pip-mode") ?: @"call";
  NSString* transition = Flag(@"--airc-pip-transition") ?: @"tab";
  BOOL negative = [mode isEqual:@"muted"] || [mode isEqual:@"audio"] || [Flag(@"--airc-pip-disabled") isEqual:@"1"];
  if (step == 0) {
    self.evidence[@"screenLocked"] = @NO;
    self.evidence[@"mode"] = mode; self.evidence[@"transition"] = transition;
    tab.profile.autoPictureInPictureEnabled = ![Flag(@"--airc-pip-disabled") isEqual:@"1"];
    tab.profile.pictureInPictureFrame = NSZeroRect;
    if ([Flag(@"--airc-pip-overlay") isEqual:@"1"]) {
      // pipcontrols: the app's controls replace Chromium's (engine/PIP.md "App overlay").
      [AircEngine setPictureInPictureOverlayProvider:^NSView*(AircTab* owner, NSDictionary* info) {
        self.evidence[@"overlayInfo"] = @{@"kind": info[@"kind"] ?: @"", @"window": @([info[@"window"] isKindOfClass:NSWindow.class]),
                                          @"ownerIsTab": @(owner == self.tabs[0])};
        return [[AircTestPipOverlay alloc] initWithFrame:NSZeroRect];
      }];
    }
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":[NSString stringWithFormat:@"start('%@')",mode], @"userGesture":@YES, @"awaitPromise":@YES, @"returnByValue":@YES} timeout:10 completion:^(NSDictionary* r, NSString* e) {
      self.evidence[@"start"] = r ?: @{};
      if (e || r[@"exceptionDetails"] || (![r[@"result"][@"value"][@"ready"] boolValue] || ![r[@"result"][@"value"][@"playing"] boolValue])) {
        [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"state()", @"returnByValue":@YES} timeout:2 completion:^(NSDictionary* detail, NSString* ignored) {
          self.evidence[@"startFailureState"] = detail ?: @{};
          [self finish:e ?: @"fixture failed"];
        }]; return;
      }
      // Let MediaSession IPCs and URL safety eligibility settle.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self pipStep:1 attempt:0]; });
    }]; return;
  }
  if (step == 1 && !self.evidence[@"focusOnlyStarted"]) {
    self.evidence[@"focusOnlyStarted"] = @YES;
    self.evidence[@"keyBefore"] = @(NSApp.keyWindow.windowNumber);
    [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidResignKeyNotification object:self.browserWindow.window];
    [tab setPictureInPictureWindowActive:NO];
    // Same input as resign-key on Notification Center/Spotlight, page visible.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1200*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"state()", @"returnByValue":@YES} timeout:3 completion:^(NSDictionary* r, NSString* e) {
        NSDictionary* state = r[@"result"][@"value"];
        BOOL ok = !e && state && ![state[@"doc"] boolValue] && ![state[@"video"] boolValue];
        self.evidence[@"focusOnlyNoPip"] = @(ok);
        if (!ok) { [tab exitPictureInPicture]; [self finish:@"focus-only change entered PiP"]; return; }
        [tab setPictureInPictureWindowActive:YES];
        [self pipStep:1 attempt:0];
      }];
    }); return;
  }
  if (step == 1) {
    if ([transition isEqual:@"window"]) {
      // Actually leave the screen, without changing the owner's focus.
      [self.browserWindow.window orderOut:nil];
      [tab setPictureInPictureWindowActive:NO];
    } else if ([transition isEqual:@"space"]) {
      // A Space crossing profiles uses the same detach/attach contract.
      [self select:1];
    } else {
      AircTab* other = [self.browserWindow openTab:@"about:blank" profile:tab.profile foreground:NO];
      [self.tabs addObject:other]; [self select:self.tabs.count-1];
    }
    [self pipLater:2 attempt:0]; return;
  }
  if (step == 2) {
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"state()", @"returnByValue":@YES} timeout:3 completion:^(NSDictionary* r, NSString* e) {
      NSDictionary* state = r[@"result"][@"value"];
      if (e || r[@"exceptionDetails"] || ![state isKindOfClass:NSDictionary.class]) {
        [tab exitPictureInPicture]; [self finish:e ?: @"missing fixture state"]; return;
      }
      if ([mode isEqual:@"call"] && !self.evidence[@"callPressure"]) {
        self.evidence[@"callPressure"] = @([AircEngine simulateMemoryPressureForTesting:2]);
        tab.profile.unloadTimeout = 0.5;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          if (tab.discarded) { [self finish:@"call discarded under pressure/timeout"]; return; }
          [self pipStep:2 attempt:attempt+1];
        }); return;
      }
      if ([mode isEqual:@"call"] && (![state[@"connected"] boolValue] || ![state[@"live"] boolValue])) {
        [self finish:@"call connection or capture lost"]; return;
      }
      BOOL active = [state[@"doc"] boolValue] || [state[@"video"] boolValue];
      self.evidence[@"away"] = state ?: @{};
      if (negative) {
        if (![state[@"readyState"] intValue]) {
          [self finish:@"negative fixture has no media data"]; return;
        }
        if (active) { [tab exitPictureInPicture]; [self finish:@"negative fixture entered PiP"]; return; }
        if (attempt < 12) { [self pipLater:2 attempt:attempt+1]; return; }
      } else if (!active) { [self pipLater:2 attempt:attempt+1]; return; }
      if (!negative && ![state[[mode isEqual:@"call"] ? @"doc" : @"video"] boolValue]) {
        [tab exitPictureInPicture]; [self finish:@"wrong PiP kind"]; return;
      }
      if ([mode isEqual:@"call"] && !self.evidence[@"paintWait"]) {
        // The Document PiP DOM becomes active before its native show animation
        // and first compositor frame. Give it 400 ms, capture, then close.
        self.evidence[@"paintWait"] = @YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
          [self pipStep:2 attempt:attempt+1];
        }); return;
      }
      for (NSWindow* window in NSApp.windows) {
        if (window != self.browserWindow.window && window.visible && window.level == NSFloatingWindowLevel) {
          self.evidence[@"window"] = @{@"frame":NSStringFromRect(window.frame), @"level":@(window.level), @"spaces":@(window.collectionBehavior), @"visible":@(window.visible)};
          self.evidence[@"capture"] = @(CaptureWindow(window, [self nativePath:@"pip.png"]));
          NSRect area = NSInsetRect(window.screen.visibleFrame, 20, 20);
          self.evidence[@"bottomRight"] = @(fabs(NSMaxX(window.frame)-NSMaxX(area)) < 2 &&
                                              fabs(NSMinY(window.frame)-NSMinY(area)) < 2);
          BOOL independent = [[window valueForKey:@"activationIndependence"] boolValue];
          NSUInteger behavior = window.collectionBehavior;
          self.evidence[@"nativeClass"] = NSStringFromClass(window.class);
          self.evidence[@"nonactivating"] = @(independent);
          self.evidence[@"collectionCorrect"] = @((behavior & NSWindowCollectionBehaviorCanJoinAllSpaces) &&
              (behavior & NSWindowCollectionBehaviorFullScreenAuxiliary) &&
              (behavior & NSWindowCollectionBehaviorCanJoinAllApplications) &&
              !(behavior & (NSWindowCollectionBehaviorMoveToActiveSpace | NSWindowCollectionBehaviorFullScreenPrimary | NSWindowCollectionBehaviorPrimary)));
          self.evidence[@"openingKeptFocus"] = @(!NSApp.active && NSApp.keyWindow.windowNumber == [self.evidence[@"keyBefore"] integerValue]);
          if ([Flag(@"--airc-pip-overlay") isEqual:@"1"]) [self pipNoteOverlay:window];
          [self pipCheckWindow:window completion:^{
            [self.browserWindow.window orderFront:nil];
            [tab setPictureInPictureWindowActive:YES]; [self select:0];
            [self pipLater:3 attempt:0];
          }];
          return;
        }
      }
      [self.browserWindow.window orderFront:nil];
      // Returning must close via Chromium's auto path.
      [tab setPictureInPictureWindowActive:YES]; [self select:0];
      [self pipLater:3 attempt:0];
    }]; return;
  }
  if (step == 3) {
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"state()", @"returnByValue":@YES} timeout:3 completion:^(NSDictionary* r, NSString* e) {
      NSDictionary* state = r[@"result"][@"value"];
      if (e || r[@"exceptionDetails"] || ![state isKindOfClass:NSDictionary.class]) {
        [tab exitPictureInPicture]; [self finish:e ?: @"missing fixture state"]; return;
      }
      self.evidence[@"returned"] = state ?: @{};
      if ([state[@"doc"] boolValue] || [state[@"video"] boolValue]) { [self pipLater:3 attempt:attempt+1]; return; }
      if (!negative && !self.evidence[@"window"]) { [self finish:@"DOM PiP but floating native window not observed"]; return; }
      if ([mode isEqual:@"call"] && (![state[@"connected"] boolValue] || ![state[@"live"] boolValue])) {
        [self finish:@"call lost after return"]; return;
      }
      if (negative) { [self finish:nil]; return; }
      if (![state[@"restored"] boolValue] || ![self.evidence[@"bottomRight"] boolValue] ||
          ![self.evidence[@"savedAfterMove"] boolValue]) {
        [self finish:@"restoration or placement assertion failed"]; return;
      }
      for (NSString* check in @[@"focusOnlyNoPip", @"nonactivating", @"collectionCorrect", @"openingKeptFocus", @"backgroundDrag", @"snapped", @"commandFree", @"flungRight", @"dragKeptFocus", @"profileFrameIsolated"])
        if (![self.evidence[check] boolValue]) { [self finish:[@"window assertion: " stringByAppendingString:check]]; return; }
      // Second automatic entry: leave the actual tab, then exercise controls.
      [self select:self.tabs.count-1]; [self pipLater:4 attempt:0];
    }]; return;
  }
  if (step == 4) {
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"state()", @"returnByValue":@YES} timeout:3 completion:^(NSDictionary* r, NSString* e) {
      NSDictionary* state = r[@"result"][@"value"];
      if (e || r[@"exceptionDetails"] || ![state isKindOfClass:NSDictionary.class]) {
        [tab exitPictureInPicture]; [self finish:e ?: @"missing reentry state"]; return;
      }
      if (![state[@"doc"] boolValue] && ![state[@"video"] boolValue]) {
        [self pipLater:4 attempt:attempt+1]; return;
      }
      if (!self.evidence[@"reentryPaint"]) {
        self.evidence[@"reentryPaint"] = @YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self pipStep:4 attempt:attempt+1]; });
        return;
      }
      BOOL remembered = NO;
      NSWindow* pipWindow = nil;
      for (NSWindow* window in NSApp.windows) {
        if (window != self.browserWindow.window && window.visible && window.level == NSFloatingWindowLevel)
          { pipWindow = window; remembered = NSEqualRects(window.frame, NSRectFromString(self.evidence[@"movedFrame"])); }
      }
      self.evidence[@"rememberedOnReentry"] = @(remembered);
      if (!remembered) { [tab exitPictureInPicture]; [self finish:@"PiP position not remembered"]; return; }
      if ([Flag(@"--airc-pip-overlay") isEqual:@"1"]) { [self pipCheckOverlay:pipWindow]; return; }
      if (![mode isEqual:@"call"]) { [self pipCheckVideoControl:pipWindow]; return; }
      [self pipClickSiteButton:@"mute" window:pipWindow completion:^{
      [self pipClickSiteButton:@"leave" window:pipWindow completion:^{
      [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"state()", @"returnByValue":@YES} timeout:3 completion:^(NSDictionary* controls, NSString* error) {
        NSDictionary* value = controls[@"result"][@"value"];
        self.evidence[@"controls"] = value ?: @{};
        [tab exitPictureInPicture];
        [self finish:!error && !NSApp.active && !controls[@"exceptionDetails"] && [value[@"muted"] boolValue] &&
            [value[@"left"] boolValue] ? nil : @"call controls failed"];
      }];
      }];
      }];
    }]; return;
  }
}

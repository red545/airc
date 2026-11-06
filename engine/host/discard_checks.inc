// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Device-free regression: multiple hidden pages in both profiles, split-like
// attach/detach/close/reopen, concurrent timeout discards and pressure.
- (void)discardCrash:(int)step {
  NSLog(@"discardcrash step %d", step);
  if (step == 0) {
    self.testProfiles = [NSMutableArray arrayWithArray:@[self.tabs[0].profile, self.tabs[1].profile]];
    for (AircProfile* profile in self.testProfiles) {
      profile.unloadTimeout = 0;
      for (int i = 0; i < 4; ++i) {
        AircTab* tab = [self.browserWindow openTab:Flag(@"--airc-test-url") profile:profile foreground:NO];
        if (!tab) { [self finish:@"initial open failed"]; return; }
        [self.tabs addObject:tab];
      }
    }
  } else if (step == 1) {
    // Show two panes in profile one, then close/reopen both as FavSplitCheck does.
    for (int i = 2; i < 4; ++i) {
      NSView* pane = [[NSView alloc] initWithFrame:NSMakeRect((i-2)*400,0,400,500)];
      [self.page addSubview:pane];
      [self.tabs[i] attachToView:pane];
    }
  } else if (step == 2) {
    [self select:0];
    // Empty the first profile, as closing the last split can do.
    for (AircTab* tab in self.tabs.copy) if (tab.profile == self.testProfiles[0]) [tab close];
  } else if (step == 3) {
    for (NSNumber* index in @[@0, @2, @3, @4, @5]) {
      int i = index.intValue;
      AircTab* tab = [self.browserWindow openTab:Flag(@"--airc-test-url") profile:self.testProfiles[0] foreground:NO];
      if (!tab) { [self finish:@"reopen failed"]; return; }
      self.tabs[i] = tab;
    }
    // Leave a selected, host-hidden Chromium tab in profile two.
    [self select:1]; [self select:0];
  } else if (step == 4) {
    for (AircProfile* profile in self.testProfiles) profile.unloadTimeout = 0.25;
  } else if (step == 5 || step == 6) {
    self.evidence[@"pressureInjected"] = @([AircEngine simulateMemoryPressureForTesting:2]);
  } else if (step == 7) {
    NSMutableArray* states = [NSMutableArray array];
    BOOL alive = YES;
    int discarded = 0;
    for (AircTab* tab in self.tabs) {
      [states addObject:@{@"id":@(tab.tabId), @"url":tab.url ?: @"nil", @"closed":@(tab.closed), @"discarded":@(tab.discarded)}];
      alive &= tab.url.length > 0 && !tab.closed;
      discarded += tab.discarded;
    }
    self.evidence[@"afterUnload"] = states;
    self.evidence[@"visibleSurvived"] = @(!self.tabs[0].discarded && self.tabs[0].url.length > 0);
    self.evidence[@"allTabsAlive"] = @(alive);
    self.evidence[@"discardCount"] = @(discarded);
    for (AircProfile* profile in self.testProfiles) {
      profile.unloadTimeout = 0;
      self.evidence[profile.name] = @([self.browserWindow tabsForProfile:profile].count);
      AircTab* opened = [self.browserWindow openTab:Flag(@"--airc-test-url") profile:profile foreground:NO];
      if (!opened) { [self finish:@"open after unload returned nil"]; return; }
      [self.tabs addObject:opened];
    }
    if (!alive || discarded < 4 || ![self.evidence[@"visibleSurvived"] boolValue]) {
      [self finish:@"discard destroyed tabs or did not free hidden pages"]; return;
    }
    [self select:2];
  } else if (step == 8) {
    AircTab* tab = self.tabs[2];
    [tab evaluate:@"post('result', JSON.stringify({restored:document.wasDiscarded,title:document.title}))" completion:^(NSString* json) {
      NSDictionary* value = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
      self.evidence[@"restored"] = value ?: @{};
      if (![value[@"restored"] boolValue]) { [self finish:@"discarded page did not restore"]; return; }
      [self discardCrash:9];
    }];
    return;
  } else if (step == 9) {
    // Deliberately close only the Chromium Browser; the native window/profile
    // remains owned by the host. Its next open must recreate the Browser.
    self.evidence[@"browserCloseAccepted"] = @([self.browserWindow executeChromeCommand:34012 profile:self.testProfiles[0]]);
  } else if (step == 10) {
    AircTab* recovered = [self.browserWindow openTab:Flag(@"--airc-test-url") profile:self.testProfiles[0] foreground:NO];
    self.evidence[@"browserRecovered"] = @(recovered != nil && recovered.profile == self.testProfiles[0]);
    [self finish:[self.evidence[@"browserCloseAccepted"] boolValue] && [self.evidence[@"browserRecovered"] boolValue] ? nil : @"missing Browser did not recover"];
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self discardCrash:step + 1]; });
}

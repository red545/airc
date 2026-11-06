// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// No DevTools connection: that would itself inhibit discard.
- (void)p13Later:(int)step attempt:(int)attempt {
  if (attempt > 150) { [self finish:[NSString stringWithFormat:@"pass13 step %d timed out", step]]; return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self p13:step attempt:attempt]; });
}
- (void)p13Read:(NSString*)script done:(void (^)(id))done {
  [self.tabs[0] evaluate:[NSString stringWithFormat:@"Promise.resolve(%@).then(value => post('result', JSON.stringify(value)))", script] completion:^(NSString* json) {
    id value = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:NSJSONReadingFragmentsAllowed error:nil] : nil;
    if (!value) { [self finish:@"pass13 evaluate failed"]; return; } done(value);
  }];
}
- (void)p13:(int)step attempt:(int)attempt {
  AircTab* tab = self.tabs[0]; AircProfile* profile = tab.profile;
  NSString* origin = Flag(@"--airc-test-url");
  if (step == 13) {
    NSArray* rows = profile.downloads;
    if (rows.count < 2) { [self p13Later:13 attempt:attempt+1]; return; }
    self.evidence[@"restoredDownloads"] = rows;
    [self finish:nil]; return;
  }
  if (step == 0) {
    __weak Host* weak = self;
    [profile observeSitePermissions:^(NSString* changed) { weak.evidence[@"permissionNotification"] = changed; }];
    BOOL ok = [profile setSitePermission:@"notifications" state:@"block" origin:origin] &&
      [[profile sitePermissions:origin][@"notifications"][@"effective"] isEqual:@"block"] &&
      ![[self.tabs[1].profile sitePermissions:origin][@"notifications"][@"effective"] isEqual:@"block"] &&
      [profile resetSitePermissions:origin] &&
      [[profile sitePermissions:origin][@"notifications"][@"state"] isEqual:@"default"] &&
      self.evidence[@"permissionNotification"] != nil &&
      [profile setSiteZoomFactor:1.25 origin:origin] && fabs([profile siteZoomFactor:origin]-1.25)<0.001 &&
      [profile resetSiteZoom:origin] && fabs([profile siteZoomFactor:origin]-profile.defaultSiteZoomFactor)<0.001;
    self.evidence[@"permissions"] = [profile sitePermissions:origin];
    self.evidence[@"security"] = tab.securityInfo;
    if (!ok) { [self finish:@"pass13 permission/zoom isolation or notification failed"]; return; }
    [profile observeMediaTabs:^(NSArray* tabs) { weak.evidence[@"mediaTabCount"] = @(tabs.count); }];
    [tab observeMediaSession:^(NSDictionary* snapshot) { weak.evidence[@"mediaUpdate"] = snapshot; }];
    // Resetting camera/microphone grants during capture correctly stops it.
    // Start the call only after the Site Controls reset assertions finish.
    [self p13Read:@"start().then(() => true, e => String(e))" done:^(id started) {
      if (![started isEqual:@YES]) { [self finish:[NSString stringWithFormat:@"call start failed: %@", started]]; return; }
      [self p13Later:1 attempt:0];
    }]; return;
  }
  if (step == 1) {
    [self p13Read:@"state()" done:^(NSDictionary* state) {
      if (![state[@"peers"] isEqual:@[@"connected",@"connected"]] ||
          ![tab.mediaSession[@"actions"] containsObject:@"togglemicrophone"]) {
        self.evidence[@"waiting"] = state; [self p13Later:1 attempt:attempt+1]; return;
      }
      if (![NSProcessInfo.processInfo.arguments containsObject:@"--use-fake-ui-for-media-stream"] &&
          (![tab.mediaSession[@"capture"][@"microphone"] boolValue] || ![tab.mediaSession[@"capture"][@"camera"] boolValue])) {
        [self finish:@"capture indicator missing fake camera/microphone"]; return;
      }
      self.evidence[@"initialCall"] = state;
      self.evidence[@"initialMedia"] = tab.mediaSession;
      if (![profile.mediaTabs containsObject:tab] || ![tab.mediaSession[@"title"] isEqual:@"Synthetic track"] ||
          ![tab performMediaAction:@"togglemicrophone" value:0] || ![tab performMediaAction:@"togglecamera" value:0] ||
          ![tab performMediaAction:@"nexttrack" value:0] || ![tab performMediaAction:@"seekto" value:20]) {
        [self finish:@"pass13 metadata, registry or action dispatch failed"]; return;
      }
      NSWindow* native = [[NSWindow alloc] initWithContentRect:NSMakeRect(200,200,600,420)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
      native.releasedWhenClosed = NO; native.level = NSFloatingWindowLevel;
      self.secondWindow = [[AircWindow alloc] initWithWindow:native hostView:native.contentView];
      [self.secondWindow prepareProfile:profile];
      [tab detachFromHost]; [tab attachToView:native.contentView]; [self.secondWindow showInactive];
      [self.browserWindow.window orderOut:nil];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self p13:16 attempt:0]; });
    }]; return;
  }
  if (step == 16) {
    if (tab.view.hidden || tab.view.window != self.secondWindow.window || !tab.pageVisible) {
      [self finish:@"source window hid the reparented call"]; return;
    }
    self.evidence[@"sourceHidePreservedCallView"] = @YES;
    [self.secondWindow.window orderOut:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self p13:17 attempt:0]; }); return;
  }
  if (step == 17) {
    if (!tab.view.hidden) { [self finish:@"floating window hide did not hide its hosted page"]; return; }
    self.evidence[@"floatingHideHidCallView"] = @YES;
    [self.secondWindow showInactive];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self p13:18 attempt:0]; }); return;
  }
  if (step == 18) {
    if (tab.view.hidden) { [self finish:@"floating window restore did not restore page"]; return; }
    self.evidence[@"floatingRestoreShowedCallView"] = @YES;
    [tab setPageVisible:NO];
    self.evidence[@"discardRefused"] = @(![tab discard]);
    [AircEngine simulateMemoryPressureForTesting:2];
    [self p13Later:2 attempt:0]; return;
  }
  if (step == 2) {
    [self p13Read:@"state()" done:^(NSDictionary* state) {
      self.evidence[@"floatingCall"] = state;
      BOOL ok = [state[@"loadID"] isEqual:self.evidence[@"initialCall"][@"loadID"]] &&
        [state[@"peers"] isEqual:@[@"connected",@"connected"]] && !tab.discarded &&
        [self.evidence[@"discardRefused"] boolValue] &&
        [state[@"events"] containsObject:@"togglemicrophone"] && [state[@"events"] containsObject:@"togglecamera"] &&
        [state[@"events"] containsObject:@"nexttrack"] && [state[@"events"] containsObject:@"seekto"] &&
        ![tab.mediaSession[@"microphoneActive"] boolValue] && ![tab.mediaSession[@"cameraActive"] boolValue];
      for (NSDictionary* track in state[@"tracks"]) ok &= [track[@"ready"] isEqual:@"live"];
      if (!ok) { [self finish:@"pass13 hidden floating call lost state or action acknowledgement"]; return; }
      [self.browserWindow showInactive];
      [tab detachFromHost]; [tab attachToView:self.page]; [tab setPageVisible:YES];
      [self.secondWindow close]; self.secondWindow = nil;
      [self p13Later:3 attempt:0];
    }]; return;
  }
  if (step == 3) {
    [self p13Read:@"state()" done:^(NSDictionary* state) {
      self.evidence[@"returnedCall"] = state;
      if (![state[@"loadID"] isEqual:self.evidence[@"initialCall"][@"loadID"]] ||
          ![state[@"peers"] isEqual:@[@"connected",@"connected"]]) { [self finish:@"call did not survive return"]; return; }
      if (![tab performMediaAction:@"hangup" value:0]) { [self finish:@"hangup unavailable"]; return; }
      [self p13Later:4 attempt:0];
    }]; return;
  }
  if (step == 4) {
    [self p13Read:@"state()" done:^(NSDictionary* state) {
      if (![state[@"events"] containsObject:@"hangup"]) { [self p13Later:4 attempt:attempt+1]; return; }
      [profile siteData:origin completion:^(NSDictionary* data) {
        self.evidence[@"dataBefore"] = data;
        if ([data[@"cookies"] intValue] < 1) { [self finish:@"site cookie count missing"]; return; }
        [profile clearSiteData:origin completion:^(BOOL ok) {
          if (!ok) { [self finish:@"site deletion failed"]; return; }
          [profile siteData:origin completion:^(NSDictionary* data) {
            self.evidence[@"dataAfter"] = data;
            if ([data[@"cookies"] intValue] != 0) { [self finish:@"site cookie remains"]; return; }
            [self p13Read:@"({cookie:document.cookie,storage:localStorage.getItem('pass13')})" done:^(NSDictionary* state) {
              self.evidence[@"dataReadback"] = state;
              if ([state[@"cookie"] length] || state[@"storage"] != NSNull.null) { [self finish:@"site data readback not empty"]; return; }
              [profile setSitePermission:@"automaticDownloads" state:@"allow" origin:origin];
              __weak Host* weak = self;
              [profile observeDownloads:^(NSDictionary* row) { weak.evidence[@"lastDownload"] = row; }];
              [tab executeJavaScript:@"location.href='/slow'" frame:nil]; [self p13Later:5 attempt:0];
            }];
          }];
        }];
      }];
    }]; return;
  }
  NSDictionary* row = self.evidence[@"lastDownload"];
  if (step == 5) {
    if (!row || [row[@"received"] longLongValue] == 0) { [self p13Later:5 attempt:attempt+1]; return; }
    NSString* identifier = row[@"id"]; self.evidence[@"safeID"] = identifier;
    BOOL ok = [profile performDownloadAction:@"pause" identifier:identifier] &&
      [profile performDownloadAction:@"open" identifier:identifier] &&
      [profile performDownloadAction:@"open" identifier:identifier];
    if (!ok) { [self finish:@"pause/open-when-done toggle failed"]; return; }
    [self p13Later:6 attempt:0]; return;
  }
  if (step == 6) {
    if (![row[@"paused"] boolValue]) { [self finish:@"paused snapshot missing"]; return; }
    self.evidence[@"pausedDownload"] = row;
    if (![profile performDownloadAction:@"resume" identifier:row[@"id"]]) { [self finish:@"resume failed"]; return; }
    [self p13Later:7 attempt:0]; return;
  }
  if (step == 7) {
    if ([row[@"state"] intValue] != 1) { [self p13Later:7 attempt:attempt+1]; return; }
    self.evidence[@"completedDownload"] = row;
    NSString* file = [profile downloadPath:row[@"id"]];
    if (!file || ![file hasPrefix:[Flag(@"--airc-data-dir") stringByAppendingString:@"/downloads/"]] ||
        !row[@"mimeType"] || !row[@"startTime"] || !row[@"fileName"] || self.tabs[1].profile.downloads.count) {
      [self finish:@"download metadata/path/profile isolation failed"]; return;
    }
    [tab executeJavaScript:@"location.href='/slow'" frame:nil]; [self p13Later:8 attempt:0]; return;
  }
  if (step == 8) {
    if ([row[@"id"] isEqual:self.evidence[@"safeID"]] || [row[@"state"] intValue] != 1) { [self p13Later:8 attempt:attempt+1]; return; }
    if ([row[@"path"] isEqual:self.evidence[@"completedDownload"][@"path"]]) { [self finish:@"download filename was not deduplicated"]; return; }
    self.evidence[@"deduplicated"] = row;
    [tab executeJavaScript:@"location.href='/interrupt'" frame:nil]; [self p13Later:9 attempt:0]; return;
  }
  if (step == 9) {
    if (![row[@"url"] hasSuffix:@"/interrupt"] || [row[@"state"] intValue] != 3) { [self p13Later:9 attempt:attempt+1]; return; }
    self.evidence[@"interrupted"] = row;
    // Chromium may automatically resume truncated responses. Keep the fixture
    // broken until an interrupted snapshot is observed, then enable our retry.
    [self p13Read:@"fetch('/allow-retry').then(r => r.ok)" done:^(id ready) {
      if (![ready boolValue] || ![profile performDownloadAction:@"retry" identifier:row[@"id"]]) {
        [self finish:@"retry rejected"]; return;
      }
      [self p13Later:10 attempt:0];
    }]; return;
  }
  if (step == 10) {
    if ([row[@"state"] intValue] != 1) { [self p13Later:10 attempt:attempt+1]; return; }
    self.evidence[@"retried"] = row;
    [tab executeJavaScript:@"location.href='/danger'" frame:nil]; [self p13Later:11 attempt:0]; return;
  }
  if (step == 11) {
    if (![row[@"url"] hasSuffix:@"/danger"] || (![row[@"dangerous"] boolValue] && [row[@"state"] intValue] == 0)) {
      [self p13Later:11 attempt:attempt+1]; return;
    }
    self.evidence[@"dangerousType"] = row;
    if ([row[@"dangerous"] boolValue]) {
      if ([profile performDownloadAction:@"open" identifier:row[@"id"]] ||
          ![profile performDownloadAction:@"discard" identifier:row[@"id"]]) { [self finish:@"danger guard/discard failed"]; return; }
    } else if (![profile performDownloadAction:@"remove" identifier:row[@"id"]]) { [self finish:@"remove failed"]; return; }
    [self p13Later:12 attempt:0]; return;
  }
  if (step == 12) {
    if (![row[@"removed"] boolValue]) { [self p13Later:12 attempt:attempt+1]; return; }
    self.evidence[@"removedDownload"] = row;
    [tab executeJavaScript:@"location.href='/slow'" frame:nil]; [self p13Later:14 attempt:0]; return;
  }
  if (step == 14) {
    if ([row[@"removed"] boolValue] || [row[@"state"] intValue] != 0) { [self p13Later:14 attempt:attempt+1]; return; }
    if (![profile performDownloadAction:@"cancel" identifier:row[@"id"]]) { [self finish:@"cancel rejected"]; return; }
    [self p13Later:15 attempt:0]; return;
  }
  if (step == 15) {
    if ([row[@"state"] intValue] != 2) { [self p13Later:15 attempt:attempt+1]; return; }
    self.evidence[@"cancelledDownload"] = row;
    if (![profile performDownloadAction:@"remove" identifier:row[@"id"]]) { [self finish:@"cancelled row removal failed"]; return; }
    self.evidence[@"downloads"] = profile.downloads;
    [profile observeDownloads:nil]; [profile observeMediaTabs:nil]; [tab observeMediaSession:nil]; [profile observeSitePermissions:nil];
    [self finish:nil];
  }
}

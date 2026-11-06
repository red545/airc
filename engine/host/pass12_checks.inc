// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Locked-screen state probes, not visual qualification.
- (BOOL)tabWantsPasswordSuggestions:(AircTab*)tab { return [Flag(@"--airc-smoke") isEqual:@"pass12"]; }
- (void)tab:(AircTab*)tab didShowAutofillSuggestions:(NSArray*)items {
  if ([self tabWantsPasswordSuggestions:tab]) self.passwordRows = items;
}
- (void)tabDidCancelClose:(AircTab*)tab { self.cancelledCloses++; }
- (void)tabDidCloseForHost:(AircTab*)tab { self.completedCloses++; }
- (void)p12Later:(int)step {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self p12:step]; });
}
- (void)p12Eval:(AircTab*)tab script:(NSString*)script done:(void (^)(id))done {
  [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":script, @"userGesture":@YES, @"awaitPromise":@YES, @"returnByValue":@YES} timeout:8 completion:^(NSDictionary* result, NSString* error) {
    if (error || result[@"exceptionDetails"]) { [self finish:error ?: result.description]; return; }
    done(result[@"result"][@"value"] ?: NSNull.null);
  }];
}
- (void)p12:(int)step {
  AircTab* tab = self.tabs[0];
  if (step == 0) {
    NSDictionary* session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    self.evidence[@"screenLocked"] = @(!session || [session[@"CGSSessionScreenIsLocked"] boolValue]);
    NSString* url = Flag(@"--airc-test-url");
    [tab.profile importLogins:@[
      @{@"origin":url,@"signonRealm":url,@"username":@"alice",@"password":@"synthetic-alice"},
      @{@"origin":url,@"signonRealm":url,@"username":@"bob",@"password":@"synthetic-bob"}]
      completion:^(NSDictionary* result) {
        self.evidence[@"loginImport"] = result;
        [tab reload]; [self p12Later:1];
      }]; return;
  }
  if (step == 1) {
    [tab focus];
    [self p12Eval:tab script:@"document.querySelector('#username').focus(); true" done:^(id value) {
      [tab showAutofillSuggestions:YES]; [self p12Later:2];
    }]; return;
  }
  if (step == 2) {
    self.evidence[@"passwordRows"] = self.passwordRows ?: @[];
    NSDictionary* bob = nil;
    for (NSDictionary* row in self.passwordRows) if ([row[@"label"] isEqual:@"bob"]) bob = row;
    if (!bob || self.passwordRows.count < 2) { [self finish:@"two password choices missing"]; return; }
    self.oldPasswordIndex = [bob[@"index"] integerValue];
    if (![tab acceptAutofillSuggestion:self.oldPasswordIndex]) { [self finish:@"selection rejected"]; return; }
    [self p12Later:3]; return;
  }
  if (step == 3) {
    [self p12Eval:tab script:@"({username:username.value,correct:password.value==='synthetic-bob'})" done:^(id value) {
      self.evidence[@"selectedPassword"] = value;
      if (![value[@"username"] isEqual:@"bob"] || ![value[@"correct"] boolValue] || [tab acceptAutofillSuggestion:self.oldPasswordIndex]) { [self finish:@"selection or stale-handle assertion failed"]; return; }
      [self p12Eval:self.tabs[1] script:@"password.value===''" done:^(id value) {
        if (![value boolValue]) { [self finish:@"password crossed profile"]; return; }
        self.evidence[@"passwordProfileIsolated"] = @YES;
        [tab hideAutofillSuggestions];
        [self p12Later:4];
      }];
    }]; return;
  }
  if (step == 4) {
    self.featureRoutes = [NSMutableArray array];
    NSString* cross = [Flag(@"--airc-test-url") stringByReplacingOccurrencesOfString:@"127.0.0.1" withString:@"localhost"];
    NSString* script = [NSString stringWithFormat:@"document.body.innerHTML='<a id=link href=%@>Cross site</a>'; link.click(); true",cross];
    [self p12Eval:tab script:script done:^(id value) { [self p12Later:5]; }]; return;
  }
  if (step == 5) {
    self.evidence[@"sameTabRoutes"] = [self.featureRoutes copy];
    if (self.featureRoutes.count != 1 || ![self.featureRoutes[0][@"disposition"] isEqual:@"current_tab"] || ![tab.url isEqual:Flag(@"--airc-test-url")]) { [self finish:@"cross-site navigation was not intercepted exactly once"]; return; }
    [self p12Eval:tab script:@"link.href='/same'; link.click(); true" done:^(id value) { [self p12Later:6]; }]; return;
  }
  if (step == 6) {
    if (self.featureRoutes.count != 1 || ![tab.url hasSuffix:@"/same"]) { [self finish:@"same-site link routed unexpectedly"]; return; }
    self.evidence[@"sameSiteNotRouted"] = @YES;
    self.featureRoutes = nil;
    [self p12Eval:tab script:@"onbeforeunload=e=>{e.preventDefault();e.returnValue='';}; true" done:^(id value) {
      [tab close]; [self p12Later:7];
    }]; return;
  }
  if (step == 7) {
    self.evidence[@"closePrompt"] = [tab modalDialogStateForTesting];
    if (![tab cancelModalDialogForTesting]) { [self finish:@"host close did not ask"]; return; }
    [self p12Later:8]; return;
  }
  if (step == 8) {
    if (tab.closed || self.cancelledCloses != 1 || self.completedCloses != 0) { [self finish:@"Stay callback mismatch"]; return; }
    self.evidence[@"stayCallback"] = @YES;
    [tab close]; [self p12Later:81]; return;
  }
  if (step == 81) {
    NSWindow* dialog = [self dialogWindow];
    if (!dialog) { [self finish:@"second close did not ask"]; return; }
    if (![tab respondToModalDialogForTesting:YES]) { [self finish:@"Leave handler missing"]; return; }
    [self p12Later:9]; return;
  }
  if (step == 9) {
    if (!tab.closed || self.completedCloses != 1) { [self finish:@"host completion callback mismatch"]; return; }
    self.evidence[@"closeCompletedOnce"] = @YES;
    // Same explicit-host entry point for a video stream tile and Little Arc.
    [self select:1];
    [self p12Eval:self.tabs[1] script:@"(async()=>{let stream=await navigator.mediaDevices.getUserMedia({video:true,audio:true});let v=document.createElement('video');v.id='tile';v.muted=true;v.srcObject=stream;document.body.append(v);await v.play();return v.readyState>0})()" done:^(id value) { [self p12Later:10]; }]; return;
  }
  if (step == 10) {
    [self.tabs[1] enterPictureInPictureForHost:^(NSString* route, BOOL opened) {
      self.evidence[@"hostPiP"] = @{@"route":route,@"opened":@(opened)};
      if (!opened) { [self finish:@"host PiP did not open"]; return; }
      [self p12Later:11];
    }]; return;
  }
  if (step == 11) {
    [self.browserWindow.window orderOut:nil];
    [self p12Later:12]; return;
  }
  if (step == 12) {
    [self p12Eval:self.tabs[1] script:@"document.pictureInPictureElement===tile" done:^(id value) {
      self.evidence[@"streamTilePiPActive"] = value;
      [self.tabs[1] exitPictureInPicture];
      if (![value boolValue]) { [self finish:@"PiP element state missing"]; return; }
      [self p12Eval:self.tabs[1] script:@"tile.srcObject.getTracks().forEach(t=>t.stop());true" done:^(id ignored) { [self finish:nil]; }];
    }]; return;
  }
}

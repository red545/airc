// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Synthetic pages, native responder input, real renderer navigation and Apple events.
- (void)featureAssert:(BOOL)ok name:(NSString*)name {
  self.evidence[name] = @(ok);
  if (!ok) [self finish:[@"feature assertion: " stringByAppendingString:name]];
}
- (void)featureEval:(AircTab*)tab code:(NSString*)code then:(void (^)(id))done {
  [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":code, @"returnByValue":@YES,
      @"awaitPromise":@YES, @"userGesture":@YES} timeout:8 completion:^(NSDictionary* r, NSString* e) {
    if (e || r[@"exceptionDetails"]) { [self finish:e ?: [r description]]; return; }
    done(r[@"result"][@"value"] ?: NSNull.null);
  }];
}
- (void)featuresStart {
  NSDictionary* session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
  self.evidence[@"screenLocked"] = @([session[@"CGSSessionScreenIsLocked"] boolValue]);
  self.featurePanes = [NSMutableArray array];
  for (int i = 2; i < 4; i++) {
    AircTab* tab = [self.browserWindow openTab:Flag(@"--airc-test-url") profile:self.tabs[i % 2].profile foreground:NO];
    tab.delegate = self; [self.tabs addObject:tab];
  }
  for (int i = 0; i < 4; i++) {
    NSView* pane = [[NSView alloc] initWithFrame:NSMakeRect(i * 280, 0, 280, 650)];
    [self.page addSubview:pane]; [self.featurePanes addObject:pane];
    [self.tabs[i] attachToView:pane];
  }
  [self featuresPane:0 attempt:0];
}
- (void)featuresPane:(int)i attempt:(int)attempt {
  if (i == 4) { [self featuresMetrics:0 before:YES]; return; }
  AircTab* tab = self.tabs[i];
  if (tab.loading) {
    if (attempt > 100) { [self finish:@"pane navigation timeout"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self featuresPane:i attempt:attempt+1]; }); return;
  }
  [self.browserWindow activateTab:tab];
  [tab focus]; tab.independentZoom = YES; tab.zoomFactor = 1 + i * .1;
  NSString* code = [NSString stringWithFormat:@"window.token='pane%d';document.body.innerHTML='<input id=edit><p>pane%dneedle</p>';document.body.style.height='5000px';document.querySelector('input').focus();true", i,i];
  [self featureEval:tab code:code then:^(id value) { [self featuresInput:i attempt:0]; }];
}
- (void)featuresInput:(int)i attempt:(int)attempt {
  AircTab* tab = self.tabs[i]; [tab focus];
  if (![AircPageView isEditingText:(id)tab.view.window.firstResponder]) {
    if (attempt > 100) { [self finish:@"pane text input state timeout"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self featuresInput:i attempt:attempt+1]; }); return;
  }
  NSEvent* event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:tab.view.window.windowNumber context:nil characters:@"x" charactersIgnoringModifiers:@"x" isARepeat:NO keyCode:7];
  [tab.view.window.firstResponder keyDown:event];
  [tab find:[NSString stringWithFormat:@"pane%dneedle",i] forward:YES];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    [self featureEval:tab code:@"document.querySelector('input').value" then:^(id value) {
      BOOL ok = [value isEqual:@"x"] && [tab.findState[@"matches"] intValue] == 1 &&
          [tab.view.window.firstResponder isKindOfClass:NSView.class] &&
          [(NSView*)tab.view.window.firstResponder isDescendantOf:tab.view];
      if (!ok) { [self finish:[NSString stringWithFormat:@"pane %d input/find failed %@ %@",i,value,tab.findState]]; return; }
      self.evidence[[NSString stringWithFormat:@"pane%dInputFind",i]] = @YES;
      [self featuresPane:i+1 attempt:0];
    }];
  });
}
- (void)featuresMetrics:(int)i before:(BOOL)before {
  if (i == 4) {
    if (before) [self featuresResize:0]; else [self featuresTools:0 attempt:0];
    return;
  }
  NSString* code = before ? @"window.resizeCount=0;window.resizeObserver=new ResizeObserver(()=>++window.resizeCount);resizeObserver.observe(document.documentElement);true" : @"({count:resizeCount,visible:document.visibilityState})";
  [self featureEval:self.tabs[i] code:code then:^(id result) {
    if (!before) {
      self.evidence[[NSString stringWithFormat:@"pane%dResize",i]] = result;
      if ([result[@"count"] intValue] > 125 || ![result[@"visible"] isEqual:@"visible"]) {
        [self finish:@"resize storm or hidden pane"]; return;
      }
    }
    [self featuresMetrics:i+1 before:before];
  }];
}
- (void)featuresResize:(int)frame {
  if (!frame) self.featureCosts = [NSMutableArray array];
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  for (int i = 0; i < 4; i++) {
    BOOL vertical = frame >= 60;
    CGFloat extent = (vertical ? 640 : 1120) + (frame % 10);
    NSRect rect = vertical ? NSMakeRect(0,i*extent/4,1120,extent/4) : NSMakeRect(i*extent/4,0,extent/4,640);
    self.featurePanes[i].frame = rect;
  }
  [self.featureCosts addObject:@((CFAbsoluteTimeGetCurrent()-start)*1000)];
  if (frame < 119) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self featuresResize:frame+1]; }); return;
  }
  self.evidence[@"resizeFrameCPUms"] = self.featureCosts;
  BOOL ok = YES;
  for (int i = 0; i < 4; i++) ok &= self.tabs[i].pageVisible && self.tabs[i].view.superview == self.featurePanes[i] && fabs(self.tabs[i].zoomFactor - (1 + i*.1)) < .001;
  if (!ok) { [self finish:@"split visibility/zoom/parent changed"]; return; }
  self.evidence[@"fourPaneVisibilityIndependentZoom"] = @YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self featuresMetrics:0 before:NO]; });
}
- (void)featuresTools:(int)i attempt:(int)attempt {
  if (i == 4) { [self.tabs[0] reload]; [self featuresZoomNavigation:0]; return; }
  AircTab* tab = self.tabs[i];
  if (!attempt) [tab showDevTools];
  if (!tab.devToolsView) {
    if (attempt > 100) { [self finish:@"per-pane DevTools timeout"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self featuresTools:i attempt:attempt+1]; }); return;
  }
  [tab attachDevToolsToView:self.featurePanes[i]];
  self.evidence[[NSString stringWithFormat:@"pane%dDevTools",i]] = @(tab.devToolsView.window == self.browserWindow.window);
  [tab.devToolsView removeFromSuperview]; [tab closeDevTools];
  [self featuresTools:i+1 attempt:0];
}
- (void)featuresZoomNavigation:(int)attempt {
  AircTab* tab = self.tabs[0];
  if (!attempt || tab.loading) {
    if (attempt > 100) { [self finish:@"zoom navigation timeout"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self featuresZoomNavigation:attempt+1]; }); return;
  }
  tab.zoomFactor = 1.7;
  BOOL isolated = tab.independentZoom && fabs(self.tabs[2].zoomFactor - 1.2) < .001;
  self.evidence[@"zoomIsolatedAfterNavigation"] = @(isolated);
  tab.zoomFactor = 1;
  if (!isolated) { [self finish:@"navigation lost zoom isolation"]; return; }
  [self featuresPeek];
}
- (void)featuresPeek {
  NSView* overlay = [[NSView alloc] initWithFrame:NSMakeRect(100,100,600,400)];
  [self.page addSubview:overlay positioned:NSWindowAbove relativeTo:nil];
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  self.featurePeek = [self.browserWindow openPeek:Flag(@"--airc-test-url") opener:self.tabs[0] inView:overlay];
  self.evidence[@"peekOpenCPUms"] = @((CFAbsoluteTimeGetCurrent()-start)*1000);
  [self featuresPeekReady:0];
}
- (void)featuresPeekReady:(int)attempt {
  AircTab* peek = self.featurePeek;
  if (peek.loading) {
    if (attempt > 100) { [self finish:@"peek load timeout"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self featuresPeekReady:attempt+1]; }); return;
  }
  if (peek.profile != self.tabs[0].profile || !self.tabs[0].pageVisible || !peek.pageVisible) { [self finish:@"peek profile/visibility failed"]; return; }
  [self featureEval:peek code:@"window.token='peek';document.querySelector('input').value='kept';window.scrollTo(0,100); const c=document.createElement('canvas');c.width=64;c.height=64;document.body.append(c);window.v=document.createElement('video');v.muted=true;v.srcObject=c.captureStream(30);document.body.append(v);window.paint=setInterval(()=>{c.getContext('2d').fillRect(0,0,64,64)},30);v.play().then(()=>({scroll:scrollY}))" then:^(id value) {
    self.evidence[@"scrollBeforeMove"] = value[@"scroll"];
    NSWindow* native = [[NSWindow alloc] initWithContentRect:NSMakeRect(200,200,480,360) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO]; native.releasedWhenClosed = NO;
    self.secondWindow = [[AircWindow alloc] initWithWindow:native hostView:native.contentView];
    // Profile selection before navigation: selecting a different profile creates no tab.
    self.secondWindow.activeProfile = self.tabs[1].profile;
    self.secondWindow.activeProfile = self.tabs[0].profile;
    self.evidence[@"littleProfileBeforeLoad"] = @([self.secondWindow tabsForProfile:self.tabs[1].profile].count == 0);
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    NSString* error = [self.secondWindow moveTab:peek profile:peek.profile toView:native.contentView];
    self.evidence[@"moveCPUms"] = @((CFAbsoluteTimeGetCurrent()-start)*1000);
    if (error) { [self finish:error]; return; }
    [self.secondWindow showInactive];
    self.evidence[@"littleOnePage"] = @([self.secondWindow tabsForProfile:peek.profile].count == 1);
    NSString* refused = [self.browserWindow moveTab:peek profile:self.tabs[1].profile toView:self.featurePanes[0]];
    self.evidence[@"crossProfileRefused"] = @([refused isEqual:@"profileMismatch"] && peek.view.window == native);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      [self featureEval:peek code:@"v.currentTime" then:^(id time) {
        self.evidence[@"mediaBeforeMove"] = time;
        NSString* error = [self.browserWindow moveTab:peek profile:peek.profile toView:self.featurePanes[0]];
        if (error) { [self finish:error]; return; }
        [self.tabs[0] setPageVisible:NO];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
          [self featureEval:peek code:@"({token,form:document.querySelector('input').value,scroll:scrollY,playing:!v.paused,time:v.currentTime})" then:^(id state) {
            self.evidence[@"promotedState"] = state;
            BOOL ok = [state[@"token"] isEqual:@"peek"] && [state[@"form"] isEqual:@"kept"] && fabs([state[@"scroll"] doubleValue] - [self.evidence[@"scrollBeforeMove"] doubleValue]) <= .5 && [state[@"playing"] boolValue] && [state[@"time"] doubleValue] > [time doubleValue];
            if (!ok) { [self finish:@"move lost live state"]; return; }
            [self featuresRouting];
          }];
        });
      }];
    });
  }];
}
- (void)featuresRouting {
  [self featureEval:self.tabs[1] code:@"document.cookie='route=two; path=/'; true" then:^(id value) { [self featuresRouteEvents]; }];
}
- (void)featuresRouteEvents {
  self.featureRoutes = [NSMutableArray array];
  [self featureEval:self.featurePeek code:[NSString stringWithFormat:@"window.open('%@popup','_blank');true",Flag(@"--airc-test-url")] then:^(id value) {
    [self featureEval:self.featurePeek code:[NSString stringWithFormat:@"const a=document.createElement('a');a.href='%@target';a.target='_blank';document.body.append(a);a.click();true",Flag(@"--airc-test-url")] then:^(id value) {
      [NSAppleEventManager.sharedAppleEventManager setEventHandler:self andSelector:@selector(featureGetURL:reply:) forEventClass:'GURL' andEventID:'GURL'];
      NSAppleEventDescriptor* target = [NSAppleEventDescriptor descriptorWithProcessIdentifier:NSProcessInfo.processInfo.processIdentifier];
      NSAppleEventDescriptor* event = [NSAppleEventDescriptor appleEventWithEventClass:'GURL' eventID:'GURL' targetDescriptor:target returnID:-1 transactionID:0];
      [event setParamDescriptor:[NSAppleEventDescriptor descriptorWithString:[Flag(@"--airc-test-url") stringByAppendingString:@"external"]] forKeyword:'----'];
      NSError* error = nil;
      [event sendEventWithOptions:NSAppleEventSendNoReply timeout:2 error:&error];
      if (error) { [self finish:error.description]; return; }
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self featuresRoutedCookies:4 attempt:0]; });
    }];
  }];
}
- (void)featuresRoutedCookies:(NSUInteger)i attempt:(int)attempt {
  if (self.tabs.count != 7 || (i < self.tabs.count && self.tabs[i].loading)) {
    if (attempt > 100) { [self finish:@"routed navigation timeout"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self featuresRoutedCookies:i attempt:attempt+1]; }); return;
  }
  if (i == 7) { [self featuresFinish]; return; }
  [self featureEval:self.tabs[i] code:@"document.cookie" then:^(id cookie) {
    if (![cookie containsString:@"route=two"]) { [self finish:@"route used wrong cookie jar"]; return; }
    self.evidence[[NSString stringWithFormat:@"route%luCookie",(unsigned long)i-4]] = cookie;
    [self featuresRoutedCookies:i+1 attempt:0];
  }];
}
- (void)featureGetURL:(NSAppleEventDescriptor*)event reply:(NSAppleEventDescriptor*)reply {
  [AircEngine.sharedEngine routeExternalURL:[event paramDescriptorForKeyword:'----'].stringValue];
}
- (void)featuresFinish {
  self.evidence[@"routes"] = self.featureRoutes;
  BOOL ok = self.featureRoutes.count == 3;
  for (NSString* key in @[@"littleOnePage", @"littleProfileBeforeLoad", @"crossProfileRefused",
      @"pane0DevTools", @"pane1DevTools", @"pane2DevTools", @"pane3DevTools"])
    ok &= [self.evidence[key] boolValue];
  for (NSDictionary* route in self.featureRoutes) {
    ok &= [route[@"handled"] boolValue] && [route[@"destinationProfileCorrect"] boolValue];
    if ([route[@"source"] isEqual:@"external"]) ok &= [route[@"sourceBundleID"] isEqual:@"dev.airc.airc-host"];
  }
  if (!ok) { [self finish:@"routing events missing"]; return; }
  [self.featurePeek close];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    self.evidence[@"peekDestroyed"] = @(self.featurePeek.closed && !self.featurePeek.view);
    if (!self.featurePeek.closed) { [self finish:@"peek close failed"]; return; }
    [self finish:nil];
  });
}

- (void)syntheticExtension {
  AircProfile* one = self.tabs[0].profile;
  [one loadUnpackedExtensionForTesting:Flag(@"--airc-extension-fixture") completion:^(NSString* extension, NSString* error) {
  if (!extension) { [self finish:@"synthetic extension load failed"]; return; }
  AircTab* popup = [self.browserWindow presentActionPopupForExtension:extension tab:self.tabs[0]
      anchorRect:NSMakeRect(20,20,20,20) inView:self.page];
  if (!popup) {
    self.evidence[@"installed"] = one.extensions;
    self.evidence[@"action"] = [self.tabs[0] actionStatesForExtensions:@[extension]];
    [self finish:@"synthetic popup failed"]; return;
  }
  self.evidence[@"absentInTwo"] = @([[self.tabs[1] executeExtensionAction:extension] isEqual:@"none"]);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    [self featureEval:popup code:@"document.querySelector('#fixture').textContent" then:^(id text) {
      self.evidence[@"popupText"] = text;
      self.evidence[@"popupProfile"] = @(popup.profile == one);
      [self.browserWindow closeActionPopup];
      BOOL ok = [text isEqual:@"Airc synthetic extension popup"] && [self.evidence[@"absentInTwo"] boolValue];
      [self finish:ok ? nil : @"extension isolation failed"];
    }];
  });
  }];
}

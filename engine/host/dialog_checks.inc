// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Synthetic credentials only. Native events target this process's dialog window.
// NSWindow frames are authoritative for layout. Also save WindowServer frames:
// locked/off-Space windows can carry a transform and must not be pixel-qualified.
- (void)recordDialogFrames:(int)step {
  NSMutableArray* samples = self.evidence[@"frameSamples"];
  if (!samples) self.evidence[@"frameSamples"] = samples = [NSMutableArray array];
  NSMutableArray* windows = [NSMutableArray array];
  for (NSWindow* w in NSApp.windows) {
    [windows addObject:@{@"number":@(w.windowNumber), @"class":NSStringFromClass(w.class),
        @"visible":@(w.visible), @"activeSpace":@(w.onActiveSpace),
        @"parent":@(w.parentWindow.windowNumber), @"frame":NSStringFromRect(w.frame),
        @"movable":@(w.movable), @"backgroundDrag":@(w.movableByWindowBackground)}];
  }
  NSMutableArray* quartz = [NSMutableArray array];
  NSArray* all = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll, kCGNullWindowID));
  for (NSDictionary* w in all) if ([w[(id)kCGWindowOwnerPID] intValue] == getpid()) {
    [quartz addObject:@{@"number":w[(id)kCGWindowNumber], @"bounds":w[(id)kCGWindowBounds],
        @"onscreen":w[(id)kCGWindowIsOnscreen] ?: @NO}];
  }
  [samples addObject:@{@"step":@(step), @"time":@(NSDate.date.timeIntervalSince1970),
      @"windows":windows, @"quartz":quartz}];
}

- (BOOL)dialogGeometryIsValid:(NSWindow*)dialog {
  NSWindow* main = self.browserWindow.window;
  NSRect page = [main convertRectToScreen:[self.page convertRect:self.page.bounds toView:nil]];
  BOOL anchored = dialog && fabs(NSMidX(dialog.frame)-NSMidX(page)) <= 1 &&
      fabs(NSMaxY(dialog.frame)-NSMaxY(page)) <= 2;
  BOOL contained = dialog && NSContainsRect(main.screen.visibleFrame, dialog.frame);
  if (!anchored || !contained) {
    self.evidence[@"badGeometry"] = @{@"page":NSStringFromRect(page),
        @"dialog":NSStringFromRect(dialog.frame), @"screen":NSStringFromRect(main.screen.visibleFrame)};
  }
  return anchored && contained;
}

- (void)dialogLater:(int)step attempt:(int)attempt {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    [self dialogStep:step attempt:attempt];
  });
}
- (NSWindow*)dialogWindow {
  NSDictionary* state = [self.tabs[0] modalDialogStateForTesting];
  for (NSDictionary* entry in state[@"dialogs"]) {
    if (![entry[@"wantsVisible"] boolValue]) continue;
    for (NSWindow* window in NSApp.windows)
      if (window.windowNumber == [entry[@"windowNumber"] integerValue]) return window;
  }
  return nil;
}

- (void)dialogEscape:(NSWindow*)window {
  NSEvent* event = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
      modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
      windowNumber:window.windowNumber context:nil characters:@"\033"
      charactersIgnoringModifiers:@"\033" isARepeat:NO keyCode:53];
  [window sendEvent:event];
}
- (void)dialogStep:(int)step attempt:(int)attempt {
  [self recordDialogFrames:step];
  AircTab* tab = self.tabs[0];
  NSString* kind = Flag(@"--airc-native-case");
  // Allow the owner time to answer a single TCC prompt. Do not invoke the
  // phone callback again while waiting; the overall runner still caps 120 s.
  const int max_attempts = step == 1 && [kind isEqual:@"hybrid"] &&
      self.evidence[@"hybridSelected"] ? 320 : 100;
  if (attempt > max_attempts) {
    NSMutableArray* windows = [NSMutableArray array];
    for (NSWindow* w in NSApp.windows) [windows addObject:@{@"title":w.title ?: @"",@"visible":@(w.visible),@"activeSpace":@(w.onActiveSpace),@"alpha":@(w.alphaValue),@"class":NSStringFromClass(w.class),@"number":@(w.windowNumber),@"parent":@(w.parentWindow.windowNumber),@"frame":NSStringFromRect(w.frame)}];
    self.evidence[@"windows"] = windows;
    self.evidence[@"nativeStateAtTimeout"] = [tab modalDialogStateForTesting];
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"onbeforeunload=null; window.abort?.abort(); window.outcome",@"returnByValue":@YES} timeout:2 completion:^(NSDictionary* r, NSString* e) {
      self.evidence[@"outcomeAtTimeout"] = r ?: @{};
      [self finish:[NSString stringWithFormat:@"dialog step %d timeout",step]];
    }]; return;
  }
  if (step == 0) {
    self.evidence[@"initialMainFrame"] = NSStringFromRect(self.browserWindow.window.frame);
    NSDictionary* session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    // Ownership and Cancel remain testable while AppKit defers off-Space drawing.
    self.evidence[@"screenLocked"] = @(!session || [session[@"CGSSessionScreenIsLocked"] boolValue]);
    if ([kind isEqual:@"virtual"]) {
      // Keep one call pending: the public one-shot CDP API otherwise detaches
      // between replies, which correctly destroys virtual authenticator state.
      [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"new Promise(resolve=>window.releaseCDP=resolve)",@"awaitPromise":@YES} timeout:30 completion:^(NSDictionary* r, NSString* e) {}];
      [tab devToolsCall:@"WebAuthn.enable" params:@{@"enableUI":@NO} timeout:5 completion:^(NSDictionary* r, NSString* e) {
        if (e) { [self finish:e]; return; }
        [tab devToolsCall:@"WebAuthn.addVirtualAuthenticator" params:@{@"options":@{@"protocol":@"ctap2",@"transport":@"internal",@"hasResidentKey":@YES,@"hasUserVerification":@YES,@"isUserVerified":@YES,@"automaticPresenceSimulation":@YES}} timeout:5 completion:^(NSDictionary* r, NSString* e) {
          if (e) { [self finish:e]; return; }
          NSString* identifier = r[@"authenticatorId"];
          [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"(async()=>{const c=await navigator.credentials.create({publicKey:{challenge:new Uint8Array(32).fill(3),rp:{name:'Synthetic Airc'},user:{id:new Uint8Array([1]),name:'fixture',displayName:'Synthetic fixture'},pubKeyCredParams:[{type:'public-key',alg:-7}],authenticatorSelection:{authenticatorAttachment:'platform',residentKey:'required',userVerification:'required'}}});const a=await navigator.credentials.get({publicKey:{challenge:new Uint8Array(32).fill(4),allowCredentials:[{id:c.rawId,type:'public-key',transports:['internal']}],userVerification:'required'}});return {created:c.type,asserted:a.type,sameId:c.id===a.id}})()",@"userGesture":@YES,@"awaitPromise":@YES,@"returnByValue":@YES} timeout:10 completion:^(NSDictionary* result, NSString* failure) {
            self.evidence[@"virtualCredential"] = result[@"result"][@"value"] ?: @{};
            [tab devToolsCall:@"WebAuthn.removeVirtualAuthenticator" params:@{@"authenticatorId":identifier} timeout:5 completion:^(NSDictionary* r, NSString* e) {
              [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"releaseCDP()"} timeout:2 completion:^(NSDictionary* r, NSString* e) {}];
              [self finish:!failure && [self.evidence[@"virtualCredential"][@"sameId"] boolValue] ? nil : (failure ?: result.description)];
            }];
          }];
        }];
      }]; return;
    }
    if ([kind hasPrefix:@"auth"]) {
      [tab loadURL:[Flag(@"--airc-test-url") stringByAppendingString:@"auth"] userInitiated:YES];
      [self dialogLater:1 attempt:0]; return;
    }
    NSString* script;
    if ([kind isEqual:@"beforeunload"]) {
      script = @"onbeforeunload=e=>{e.preventDefault();e.returnValue='';}; document.body.innerHTML='<button style=width:200px;height:100px>Arm leave-site dialog</button>'";
    } else {
      script = [NSString stringWithFormat:@"window.abort=new AbortController(); window.outcome='pending'; navigator.credentials.get({signal:abort.signal,publicKey:{challenge:new Uint8Array(32).fill(7),rpId:'localhost',allowCredentials:[{type:'public-key',id:new Uint8Array(32).fill(9),transports:%@}],timeout:60000}}).then(()=>outcome='success',e=>outcome=e.name); 'started'", [kind isEqual:@"platform"] ? @"['internal']" : @"['internal','hybrid']"];
    }
    if ([kind isEqual:@"hybrid"] || [kind isEqual:@"hybrid-picker"]) {
      script = @"window.abort=new AbortController(); window.outcome='pending'; navigator.credentials.create({signal:abort.signal,publicKey:{challenge:new Uint8Array(32).fill(7),rp:{id:'localhost',name:'Synthetic Airc'},user:{id:new Uint8Array([1]),name:'fixture',displayName:'Synthetic fixture'},pubKeyCredParams:[{type:'public-key',alg:-7}],hints:['hybrid'],authenticatorSelection:{authenticatorAttachment:'cross-platform'},timeout:60000}}).then(()=>outcome='success',e=>outcome=e.name); 'started'";
    }
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":script, @"userGesture":@YES} timeout:5 completion:^(NSDictionary* r, NSString* e) {
      if (e || r[@"exceptionDetails"]) { [self finish:e ?: r.description]; return; }
      if ([kind isEqual:@"beforeunload"]) {
        [tab devToolsCall:@"Input.dispatchMouseEvent" params:@{@"type":@"mousePressed",@"x":@60,@"y":@40,@"button":@"left",@"clickCount":@1} timeout:5 completion:^(NSDictionary* r, NSString* e) {
          [tab devToolsCall:@"Input.dispatchMouseEvent" params:@{@"type":@"mouseReleased",@"x":@60,@"y":@40,@"button":@"left",@"clickCount":@1} timeout:5 completion:^(NSDictionary* r, NSString* e) {
            [tab loadURL:[Flag(@"--airc-test-url") stringByAppendingString:@"away"] userInitiated:YES];
            [self dialogLater:1 attempt:0];
          }];
        }];
      } else [self dialogLater:1 attempt:0];
    }]; return;
  }
  if (step == 1) {
    NSWindow* dialog = [self dialogWindow];
    if (!dialog) { [self dialogLater:step attempt:attempt+1]; return; }
    NSDictionary* state = [tab modalDialogStateForTesting];
    if ([kind isEqual:@"hybrid"] && !self.evidence[@"hybridSelected"]) {
      self.evidence[@"mechanismState"] = state;
      if (![tab selectHybridMechanismForTesting]) {
        [self finish:@"phone mechanism unavailable"]; return;
      }
      self.evidence[@"hybridSelected"] = @YES;
      [self dialogLater:1 attempt:0]; return;
    }
    if ([kind isEqual:@"hybrid"] && ![state[@"webauthnStep"] isEqual:@"kCableV2QRCode"]) {
      // Do not open System Settings, alter Bluetooth or repeatedly request TCC.
      if (![state[@"webauthnStep"] isEqual:@"kBlePermissionMac"] && attempt < max_attempts) {
        [self dialogLater:1 attempt:attempt+1]; return;
      }
      self.evidence[@"hybridBlockedState"] = state;
      [tab cancelModalDialogForTesting];
      [self finish:@"hybrid qualification blocked before QR sheet (see hybridBlockedState)"]; return;
    }
    self.evidence[@"nativeState"] = state;
    // Read the Cocoa proxy independently so this assertion also fails against
    // the previous framework (whose diagnostic dictionary lacks visibility).
    NSWindow* proxy = nil;
    for (NSWindow* candidate in NSApp.windows) {
      if (candidate != self.browserWindow.window &&
          NSEqualRects(candidate.frame, NSRectFromString(state[@"modalParentFrame"] ?: @"")))
        proxy = candidate;
    }
    self.evidence[@"offSpaceParentCheck"] = self.browserWindow.window.onActiveSpace
        ? @"not exercised: main window on active Space" : @"exercised";
    if (!self.browserWindow.window.onActiveSpace && proxy.visible) {
      [self finish:@"modal parent shown while main window is off-Space"]; return;
    }
    NSDictionary* entry = [state[@"dialogs"] firstObject];
    if (![state[@"registeredHost"] boolValue] ||
        ![state[@"hostViewInAppWindow"] boolValue] || ![state[@"tabVisible"] boolValue] ||
        ![entry[@"registeredParentMatchesHost"] boolValue] || ![entry[@"childModal"] boolValue] ||
        ![entry[@"wantsVisible"] boolValue]) {
      [self finish:@"invalid native modal ownership/visibility"]; return;
    }
    if (![self dialogGeometryIsValid:dialog] ||
        !NSEqualRects(self.browserWindow.window.frame, NSRectFromString(self.evidence[@"initialMainFrame"]))) {
      [self finish:@"dialog not anchored to page or main window moved while opening"]; return;
    }
    self.evidence[@"onActiveSpace"] = @(dialog.onActiveSpace);
    self.evidence[@"dialogClass"] = NSStringFromClass(dialog.class);
    self.evidence[@"dialogFrame"] = NSStringFromRect(dialog.frame);
    self.evidence[@"hostFrame"] = NSStringFromRect(self.browserWindow.window.frame);
    self.evidence[@"parentChain"] = @(dialog.parentWindow.parentWindow == self.browserWindow.window);
    self.evidence[@"intersectsPage"] = @(NSIntersectsRect(dialog.frame, self.browserWindow.window.frame));
    self.evidence[@"capture"] = @(![self.evidence[@"screenLocked"] boolValue] && CaptureWindow(dialog,[self nativePath:@"dialog.png"]));
    // Switch profiles/Spaces: manager must hide, then restore this same dialog.
    self.evidence[@"dialogNumber"] = @(dialog.windowNumber);
    if ([kind isEqual:@"auth-close"]) { [tab close]; [self dialogLater:7 attempt:0]; return; }
    [self select:1]; [self dialogLater:2 attempt:0]; return;
  }
  if (step == 2) {
    if ([self dialogWindow]) { [self finish:@"dialog leaked across profile switch"]; return; }
    self.evidence[@"hiddenOnSpaceSwitch"] = @YES;
    [self select:0]; [self dialogLater:3 attempt:0]; return;
  }
  if (step == 3) {
    NSWindow* dialog = [self dialogWindow];
    if (!dialog) { [self dialogLater:step attempt:attempt+1]; return; }
    self.evidence[@"restoredSameDialog"] = @(dialog.windowNumber == [self.evidence[@"dialogNumber"] integerValue]);
    if (!self.evidence[@"hiddenOnTabSwitch"]) {
      AircTab* other = [self.browserWindow openTab:@"about:blank" profile:tab.profile foreground:NO];
      [self.tabs addObject:other]; [self select:self.tabs.count-1];
      [self dialogLater:6 attempt:0]; return;
    }
    if (![self.evidence[@"pageResizeChecked"] boolValue]) {
      // Exercise an inset page and restore without moving the app's window.
      self.evidence[@"originalPageFrame"] = NSStringFromRect(self.page.frame);
      self.page.frame = NSInsetRect(self.page.frame, 24, 12);
      [self dialogLater:8 attempt:0]; return;
    }
    if (![self dialogGeometryIsValid:dialog] ||
        !NSEqualRects(self.browserWindow.window.frame, NSRectFromString(self.evidence[@"initialMainFrame"]))) {
      [self finish:@"dialog restore/resize moved the main window or lost its page anchor"]; return;
    }
    self.evidence[@"frameBeforeMove"] = NSStringFromRect(dialog.frame);
    [self.browserWindow.window setFrameOrigin:NSMakePoint(self.browserWindow.window.frame.origin.x+40,self.browserWindow.window.frame.origin.y+20)];
    [self dialogLater:5 attempt:0]; return;
  }
  if (step == 8) {
    if (![self dialogGeometryIsValid:[self dialogWindow]]) {
      [self finish:@"dialog lost page anchor after page resize"]; return;
    }
    self.page.frame = NSRectFromString(self.evidence[@"originalPageFrame"]);
    self.evidence[@"pageResizeChecked"] = @YES;
    [self dialogLater:3 attempt:0]; return;
  }
  if (step == 7) {
    for (NSWindow* window in NSApp.windows) {
      if (window.windowNumber == [self.evidence[@"dialogNumber"] integerValue] &&
          window.visible) {
        [self dialogLater:7 attempt:attempt+1]; return;
      }
    }
    // The removed tab no longer has a host. Inspect its surviving sibling's
    // registered parent as well as the native window's on-screen state.
    self.evidence[@"afterTabClose"] = [self.tabs[1] modalDialogStateForTesting];
    if ([self.evidence[@"afterTabClose"][@"dialogs"] count]) {
      [self dialogLater:7 attempt:attempt+1]; return;
    }
    self.evidence[@"closedWithTab"] = @YES;
    [self finish:nil]; return;
  }
  if (step == 6) {
    if ([self dialogWindow]) { [self finish:@"dialog leaked across tab switch"]; return; }
    self.evidence[@"hiddenOnTabSwitch"] = @YES;
    [self select:0]; [self dialogLater:3 attempt:0]; return;
  }
  if (step == 5) {
    NSWindow* dialog = [self dialogWindow];
    NSPoint origin = NSRectFromString(self.evidence[@"frameBeforeMove"]).origin;
    BOOL moved = fabs(dialog.frame.origin.x-origin.x-40)<2 && fabs(dialog.frame.origin.y-origin.y-20)<2;
    if (!moved && attempt < 8) { [self dialogLater:5 attempt:attempt+1]; return; }
    self.evidence[@"movedWithWindow"] = @(moved);
    if (![self dialogGeometryIsValid:dialog]) { [self finish:@"dialog lost page anchor after window move"]; return; }
    self.evidence[@"mainBeforeCancel"] = NSStringFromRect(self.browserWindow.window.frame);
    if (dialog.visible && ![self.evidence[@"screenLocked"] boolValue]) {
      [self dialogEscape:dialog];
      self.evidence[@"cancelMethod"] = @"native Escape event";
    } else {
      self.evidence[@"cancelMethod"] = @"dialog Cancel button handler (locked or off active Space)";
      if (![tab cancelModalDialogForTesting]) { [self finish:@"no dialog Cancel handler"]; return; }
    }
    [self dialogLater:4 attempt:0]; return;
  }
  if (step == 4) {
    if ([self dialogWindow]) { [self dialogLater:step attempt:attempt+1]; return; }
    if (!NSEqualRects(self.browserWindow.window.frame, NSRectFromString(self.evidence[@"mainBeforeCancel"]))) {
      [self finish:@"Cancel moved the main window"]; return;
    }
    self.evidence[@"cancelled"] = @YES;
    self.evidence[@"afterCancel"] = [tab modalDialogStateForTesting];
    if ([self.evidence[@"afterCancel"][@"dialogs"] count] || ![self.evidence[@"restoredSameDialog"] boolValue] || ![self.evidence[@"movedWithWindow"] boolValue]) {
      [self finish:@"dialog restore/movement failed"]; return;
    }
    if ([kind isEqual:@"beforeunload"]) {
      [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"onbeforeunload=null; location.pathname",@"returnByValue":@YES} timeout:5 completion:^(NSDictionary* r, NSString* e) {
        self.evidence[@"stayedOnPage"] = @([r[@"result"][@"value"] isEqual:@"/"]);
        [self finish:[self.evidence[@"stayedOnPage"] boolValue] ? nil : @"Cancel navigated away"];
      }]; return;
    }
    if ([kind hasPrefix:@"auth"]) {
      [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"document.body.innerText",@"returnByValue":@YES} timeout:5 completion:^(NSDictionary* r, NSString* e) {
        self.evidence[@"authResponse"] = r[@"result"][@"value"] ?: @"";
        [self finish:[self.evidence[@"authResponse"] isEqual:@"Synthetic auth cancelled"] ? nil : @"Cancel did not display the 401 response"];
      }]; return;
    }
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"outcome",@"returnByValue":@YES} timeout:5 completion:^(NSDictionary* r, NSString* e) {
      self.evidence[@"credentialOutcome"] = r[@"result"][@"value"] ?: @"missing";
      [self finish:[self.evidence[@"credentialOutcome"] isEqual:@"NotAllowedError"] ? nil : @"WebAuthn cancel did not reject"];
    }]; return;
  }
}

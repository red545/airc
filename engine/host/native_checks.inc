// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Included inside Host's implementation. Never activates the app or sends global input.
- (NSString*)nativePath:(NSString*)name {
  return [[Flag(@"--airc-report") stringByDeletingLastPathComponent] stringByAppendingPathComponent:name];
}
- (void)nativeStep:(int)step attempt:(int)attempt {
  NSDictionary* session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
  if (!session || [session[@"CGSSessionScreenIsLocked"] boolValue] || NSApp.active) {
    for (NSWindow* window in NSApp.windows)
      if ([window isKindOfClass:NSOpenPanel.class]) [(NSOpenPanel*)window cancel:nil];
    if (NSApp.modalWindow) [NSApp abortModal];
    [self finish:@"screen locked or app activated; stopped native qualification"]; return;
  }
  if (attempt > 60) {
    for (NSWindow* window in NSApp.windows)
      if ([window isKindOfClass:NSOpenPanel.class]) [(NSOpenPanel*)window cancel:nil];
    [NSApp abortModal];
    [self finish:[NSString stringWithFormat:@"native step %d timed out", step]]; return;
  }
  AircTab* tab = self.tabs[0];
  if (step == 0 && [Flag(@"--airc-native-case") isEqual:@"pip"]) { [self pipStep:0 attempt:0]; return; }
  if (step == 0 && [Flag(@"--airc-native-case") isEqual:@"media"]) {
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"(async()=>{const s=await navigator.mediaDevices.getUserMedia({video:true,audio:true});const kinds=s.getTracks().map(t=>t.kind);s.getTracks().forEach(t=>t.stop());return kinds.includes('video')&&kinds.includes('audio')})()", @"userGesture":@YES, @"awaitPromise":@YES, @"returnByValue":@YES} timeout:8 completion:^(NSDictionary* r, NSString* e) {
      self.evidence[@"fakeMediaAllowedAndStopped"] = r[@"result"][@"value"] ?: @NO;
      [self finish:[self.evidence[@"fakeMediaAllowedAndStopped"] boolValue] ? nil : (e ?: @"fake media grant failed")];
    }]; return;
  }
  if (step == 30) {
    if (![self.evidence[@"cocoaTracking"] boolValue] && attempt < 12) { [self nativeLater:30 attempt:attempt+1]; return; }
    [self finish:[self.evidence[@"cocoaTracking"] boolValue] ? nil : @"Cocoa tracking not observed"]; return;
  }
  if (step == 0 && [Flag(@"--airc-native-case") isEqual:@"context"]) {
    [self select:0];
    [NSNotificationCenter.defaultCenter addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil usingBlock:^(NSNotification* n) {
      NSMenu* menu = n.object;
      self.evidence[@"cocoaTracking"] = @YES;
      self.evidence[@"nativeMenuTitles"] = [menu.itemArray valueForKey:@"title"];
      NSTimer* timer = [NSTimer timerWithTimeInterval:0.5 repeats:NO block:^(NSTimer* t) {
        [menu cancelTracking];
      }];
      [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    }];
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"document.body.innerHTML='<a style=display:block;padding:30px href=https://space.example.test/>Space link</a>'"} timeout:5 completion:^(NSDictionary* r, NSString* e) {
      [tab devToolsCall:@"Input.dispatchMouseEvent" params:@{@"type":@"mousePressed", @"x":@40, @"y":@40, @"button":@"right", @"clickCount":@1} timeout:5 completion:^(NSDictionary* r, NSString* e) {
        [tab devToolsCall:@"Input.dispatchMouseEvent" params:@{@"type":@"mouseReleased", @"x":@40, @"y":@40, @"button":@"right", @"clickCount":@1} timeout:5 completion:^(NSDictionary* r, NSString* e) {
          [self nativeLater:30 attempt:0];
        }];
      }];
    }]; return;
  }
  if (step == 0 && [Flag(@"--airc-native-case") isEqual:@"devtools"]) { [self devtoolsTest]; return; }
  if (step == 0 && [Flag(@"--airc-native-case") isEqual:@"video"]) { [self videoStep:0]; return; }
  if (step == 0 && [Flag(@"--airc-native-case") isEqual:@"permissions"]) { [self surfaceStep:0]; return; }
  if (step == 0 && [Flag(@"--airc-native-case") isEqual:@"forms"]) { [self formStep:0 attempt:0]; return; }
  if (step == 0 && [Flag(@"--airc-native-case") isEqual:@"print"]) {
    NSPrintInfo.sharedPrintInfo.jobDisposition = NSPrintSaveJob;
    NSPrintInfo.sharedPrintInfo.dictionary[NSPrintJobSavingURL] = [NSURL fileURLWithPath:[self nativePath:@"native-print.pdf"]];
    self.evidence[@"printDispatched"] = @([tab executeChromeCommand:35007]);
    [self nativeLater:6 attempt:0]; return;
  }
  if (step == 0) {
    [tab loadURL:[@"view-source:" stringByAppendingString:Flag(@"--airc-test-url")] userInitiated:YES];
    [self nativeLater:1 attempt:0]; return;
  }
  if (step == 1 && !tab.loading && [tab.url hasPrefix:@"view-source:"]) {
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"document.body.innerText.includes('Synthetic forms')", @"returnByValue":@YES}
        timeout:5 completion:^(NSDictionary* result, NSString* error) {
      self.evidence[@"viewSourceText"] = result[@"result"][@"value"] ?: @NO;
      self.evidence[@"viewSourceCapture"] = @(CaptureWindow(self.browserWindow.window, [self nativePath:@"view-source.png"]));
      [tab loadURL:Flag(@"--airc-test-url") userInitiated:YES];
      [self nativeLater:2 attempt:0];
    }]; return;
  }
  if (step == 2 && !tab.loading && ![tab.url hasPrefix:@"view-source:"]) {
    [@"Synthetic upload fixture\n" writeToFile:[self nativePath:@"upload-fixture.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"document.getElementById('upload').click()", @"userGesture":@YES}
        timeout:5 completion:^(NSDictionary* result, NSString* error) { [self nativeLater:3 attempt:0]; }]; return;
  }
  if (step == 3 && [self.browserWindow.window.attachedSheet isKindOfClass:NSOpenPanel.class]) {
    NSOpenPanel* panel = (NSOpenPanel*)self.browserWindow.window.attachedSheet;
    panel.directoryURL = [NSURL fileURLWithPath:[[self nativePath:@"upload-fixture.txt"] stringByDeletingLastPathComponent]];
    panel.nameFieldStringValue = @"upload-fixture.txt";
    [self nativeLater:4 attempt:0]; return;
  }
  if (step == 4) {
    NSOpenPanel* panel = (NSOpenPanel*)self.browserWindow.window.attachedSheet;
    self.evidence[@"uploadCapture"] = @(CaptureWindow(panel, [self nativePath:@"upload-picker.png"]));
    // NSSavePanel's inherited ok: throws on current macOS. Use the panel's
    // actual default button, without synthesizing input into another app.
    NSButtonCell* button = panel.defaultButtonCell;
    if (!button || !button.enabled) {
      [panel cancel:nil];
      [self finish:@"upload panel has no enabled default button; selection unqualified"]; return;
    }
    [button performClick:panel.contentView];
    [self nativeLater:5 attempt:0]; return;
  }
  if (step == 5 && !self.browserWindow.window.attachedSheet) {
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"document.getElementById('upload').files[0]?.name==='upload-fixture.txt'", @"returnByValue":@YES}
        timeout:5 completion:^(NSDictionary* result, NSString* error) {
      self.evidence[@"uploadSelected"] = result[@"result"][@"value"] ?: @NO;
      // The native panel remains visible. Configure its initial PDF destination;
      // this is not a claim that a human used the PDF dropdown/save subdialog.
      NSPrintInfo.sharedPrintInfo.jobDisposition = NSPrintSaveJob;
      NSPrintInfo.sharedPrintInfo.dictionary[NSPrintJobSavingURL] = [NSURL fileURLWithPath:[self nativePath:@"native-print.pdf"]];
      self.evidence[@"printDispatched"] = @([tab executeChromeCommand:35007]);
      [self nativeLater:6 attempt:0];
    }]; return;
  }
  if (step == 6 && NSApp.modalWindow) {
    self.evidence[@"printPanelClass"] = NSStringFromClass(NSApp.modalWindow.class);
    self.evidence[@"printCapture"] = @(CaptureWindow(NSApp.modalWindow, [self nativePath:@"print-panel.png"]));
    [NSApp stopModalWithCode:NSModalResponseOK];
    [self nativeLater:7 attempt:0]; return;
  }
  if (step == 7) {
    NSData* pdf = [NSData dataWithContentsOfFile:[self nativePath:@"native-print.pdf"]];
    if (pdf.length > 5) {
      self.evidence[@"nativePDF"] = @([[pdf subdataWithRange:NSMakeRange(0,5)] isEqual:[@"%PDF-" dataUsingEncoding:NSUTF8StringEncoding]]);
      self.evidence[@"applicationActive"] = @(NSApp.active);
      [[NSFileManager defaultManager] removeItemAtPath:[self nativePath:@"native-print.pdf"] error:nil];
      self.evidence[@"pdfDeleted"] = @(![[NSFileManager defaultManager] fileExistsAtPath:[self nativePath:@"native-print.pdf"]]);
      if ([Flag(@"--airc-native-case") isEqual:@"print"]) {
        [self finish:[self.evidence[@"nativePDF"] boolValue] ? nil : @"invalid PDF"]; return;
      }
      BOOL ok = [self.evidence[@"viewSourceText"] boolValue] && [self.evidence[@"uploadSelected"] boolValue] &&
          [self.evidence[@"nativePDF"] boolValue] && [self.evidence[@"printCapture"] boolValue] &&
          [self.evidence[@"uploadCapture"] boolValue] && [self.evidence[@"viewSourceCapture"] boolValue];
      [self finish:ok ? nil : @"native source/upload/PDF assertion failed"]; return;
    }
  }
  [self nativeLater:step attempt:attempt+1];
}
- (void)nativeLater:(int)step attempt:(int)attempt {
  // CF common modes include native modal panels; a dispatch timer alone may stall.
  CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, ^{
    NSTimer* timer = [NSTimer timerWithTimeInterval:0.25 repeats:NO block:^(NSTimer*) {
      [self nativeStep:step attempt:attempt];
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
  });
  CFRunLoopWakeUp(CFRunLoopGetMain());
}

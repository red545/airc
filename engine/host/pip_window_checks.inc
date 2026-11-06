// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Included inside Host. Events go to this process's PiP only, never CGEventPost.
- (void)pipMouse:(NSEventType)type window:(NSWindow*)window screen:(NSPoint)point
           flags:(NSEventModifierFlags)flags time:(NSTimeInterval)time {
  [window sendEvent:[NSEvent mouseEventWithType:type
      location:[window convertPointFromScreen:point] modifierFlags:flags timestamp:time
      windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1]];
}
- (void)pipDrag:(NSWindow*)window origin:(NSPoint)origin command:(BOOL)command fling:(BOOL)fling
    completion:(void (^)(void))completion {
  // Video center is a drag region. In the Document fixture the video is at the
  // top of the web content, away from the two DOM buttons and native toolbar.
  NSPoint start = NSMakePoint(NSMinX(window.frame)+25, NSMaxY(window.frame)-100);
  NSPoint end = NSMakePoint(start.x+origin.x-NSMinX(window.frame),
                            start.y+origin.y-NSMinY(window.frame));
  NSEventModifierFlags flags = command ? NSEventModifierFlagCommand : 0;
  // Keep the whole synthetic sequence in the past: future timestamps trip
  // Chromium compositor latency DCHECKs when the renderer consumes input.
  NSTimeInterval time = NSProcessInfo.processInfo.systemUptime - 2;
  [self pipMouse:NSEventTypeLeftMouseDown window:window screen:start flags:flags time:time];
  // Let the Document PiP isolated-world hit test complete.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (command ? 0 : 300)*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    [self pipMouse:NSEventTypeLeftMouseDragged window:window screen:NSMakePoint((start.x+end.x)/2, (start.y+end.y)/2) flags:flags time:time+(fling ? 0.01 : 0.4)];
    [self pipMouse:NSEventTypeLeftMouseDragged window:window screen:end flags:flags time:time+(fling ? 0.02 : 0.8)];
    if (!command) self.evidence[@"pointerMoved"] = @(hypot(window.frame.origin.x-origin.x, window.frame.origin.y-origin.y)<2);
    [self pipMouse:NSEventTypeLeftMouseUp window:window screen:end flags:flags time:time+(fling ? 0.03 : 1.1)];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000*NSEC_PER_MSEC), dispatch_get_main_queue(), completion);
  });
}
- (void)pipCheckWindow:(NSWindow*)window completion:(void (^)(void))completion {
  NSRect area = NSInsetRect(window.screen.visibleFrame, 20, 20);
  NSPoint corner = NSMakePoint(NSMinX(area), NSMaxY(area)-NSHeight(window.frame));
  NSPoint drop = NSMakePoint(corner.x+70, corner.y-60);
  [self pipDrag:window origin:drop command:NO fling:NO completion:^{
    self.evidence[@"snapped"] = @(hypot(window.frame.origin.x-corner.x, window.frame.origin.y-corner.y)<2);
    self.evidence[@"backgroundDrag"] = self.evidence[@"pointerMoved"];
    [self pipDrag:window origin:NSMakePoint(corner.x+90, corner.y-20) command:NO fling:YES completion:^{
    self.evidence[@"flungRight"] = @(fabs(NSMaxX(window.frame)-NSMaxX(area))<2);
    NSPoint free = NSMakePoint(corner.x+90, corner.y-80);
    [self pipDrag:window origin:free command:YES fling:NO completion:^{
      self.evidence[@"commandFree"] = @(hypot(window.frame.origin.x-free.x, window.frame.origin.y-free.y)<2);
      self.evidence[@"movedFrame"] = NSStringFromRect(window.frame);
      self.evidence[@"profileFrameIsolated"] = @(NSEqualRects(self.tabs[1].profile.pictureInPictureFrame, NSZeroRect));
      self.evidence[@"savedAfterMove"] = @(NSEqualRects(self.tabs[0].profile.pictureInPictureFrame, window.frame));
      self.evidence[@"dragKeptFocus"] = @(!NSApp.active && NSApp.keyWindow.windowNumber == [self.evidence[@"keyBefore"] integerValue]);
      completion();
    }];
    }];
  }];
}

- (void)pipClickSiteButton:(NSString*)button window:(NSWindow*)window completion:(void (^)(void))completion {
  NSString* js = [NSString stringWithFormat:@"(()=>{let w=documentPictureInPicture.window,r=w.document.getElementById('%@').getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2,h:w.innerHeight}})()", button];
  [self.tabs[0] devToolsCall:@"Runtime.evaluate" params:@{@"expression":js, @"returnByValue":@YES} timeout:3 completion:^(NSDictionary* r, NSString* error) {
    NSDictionary* v = r[@"result"][@"value"];
    if (error || !v) { [self finish:@"missing site control bounds"]; return; }
    NSPoint p = NSMakePoint(NSMinX(window.frame)+[v[@"x"] doubleValue],
                            NSMinY(window.frame)+[v[@"h"] doubleValue]-[v[@"y"] doubleValue]);
    // Keep the whole synthetic sequence in the past: future timestamps trip
  // Chromium compositor latency DCHECKs when the renderer consumes input.
  NSTimeInterval time = NSProcessInfo.processInfo.systemUptime - 2;
    self.evidence[@"beforeControlActive"] = @(NSApp.active);
    [self pipMouse:NSEventTypeLeftMouseDown window:window screen:p flags:0 time:time];
    [self pipMouse:NSEventTypeLeftMouseUp window:window screen:p flags:0 time:time+0.1];
    self.evidence[@"afterControlActive"] = @(NSApp.active);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400*NSEC_PER_MSEC), dispatch_get_main_queue(), completion);
  }];
}

- (id)pipPlaybackControl:(id)element depth:(int)depth {
  if (!element || depth > 20) return nil;
  NSString* label = [element respondsToSelector:@selector(accessibilityLabel)] ? [element accessibilityLabel] : nil;
  if (!label.length && [element respondsToSelector:@selector(accessibilityTitle)]) label = [element accessibilityTitle];
  if (!label.length && [element respondsToSelector:@selector(accessibilityHelp)]) label = [element accessibilityHelp];
  NSString* role = [element respondsToSelector:@selector(accessibilityRole)] ? [element accessibilityRole] : nil;
  if ([role isEqual:NSAccessibilityButtonRole] && ([label localizedCaseInsensitiveContainsString:@"pause"] || [label localizedCaseInsensitiveContainsString:@"play"])) return element;
  NSArray* children = [element respondsToSelector:@selector(accessibilityChildren)] ? [element accessibilityChildren] : @[];
  for (id child in children) { id found = [self pipPlaybackControl:child depth:depth+1]; if (found) return found; }
  return nil;
}
- (void)pipHoverView:(NSView*)view event:(NSEvent*)event {
  if ([NSStringFromClass(view.class) isEqual:@"BridgedContentView"]) [view mouseMoved:event];
  for (NSView* child in view.subviews) [self pipHoverView:child event:event];
}
- (void)pipCheckVideoControl:(NSWindow*)window {
  NSPoint point = NSMakePoint(NSWidth(window.frame)/2, NSHeight(window.frame)/2);
  NSEvent* move = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:point modifierFlags:0
      timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
      eventNumber:2 clickCount:0 pressure:0];
  window.acceptsMouseMovedEvents = YES;
  [self pipHoverView:window.contentView event:move];
  [window sendEvent:move];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    id button = [self pipPlaybackControl:window depth:0];
    if (!button) { [self.tabs[0] exitPictureInPicture]; [self finish:@"native playback control not found"]; return; }
    self.evidence[@"controlsCapture"] = @(CaptureWindow(window, [self nativePath:@"pip-controls.png"]));
    NSRect bounds = [button accessibilityFrame];
    NSPoint p = NSMakePoint(NSMidX(bounds), NSMidY(bounds));
    // Keep the whole synthetic sequence in the past: future timestamps trip
  // Chromium compositor latency DCHECKs when the renderer consumes input.
  NSTimeInterval time = NSProcessInfo.processInfo.systemUptime - 2;
    self.evidence[@"beforeControlActive"] = @(NSApp.active);
    [self pipMouse:NSEventTypeLeftMouseDown window:window screen:p flags:0 time:time];
    [self pipMouse:NSEventTypeLeftMouseUp window:window screen:p flags:0 time:time+0.1];
    self.evidence[@"afterControlActive"] = @(NSApp.active);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      [self.tabs[0] devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"state()", @"returnByValue":@YES} timeout:3 completion:^(NSDictionary* r, NSString* e) {
        self.evidence[@"nativeVideoPause"] = @(!e && [r[@"result"][@"value"][@"paused"] boolValue]);
        self.evidence[@"beforeCloseActive"] = @(NSApp.active);
        [self.tabs[0] exitPictureInPicture];
        self.evidence[@"afterCloseActive"] = @(NSApp.active);
        [self finish:[self.evidence[@"nativeVideoPause"] boolValue] && !NSApp.active ? nil : @"native pause failed or activated app"];
      }];
    });
  });
}

// pipcontrols (--airc-pip-overlay=1): the app overlay replaces Chromium's
// controls and keeps pipwindow's drag, snapping and nonactivation.
- (void)pipNoteOverlay:(NSWindow*)window {
  NSDictionary* state = self.tabs[0].pictureInPictureState;
  id overlay = state[@"appOverlay"];
  self.evidence[@"overlayInstalled"] = @([overlay isKindOfClass:AircTestPipOverlay.class] &&
      [overlay superview] == window.contentView && window.contentView.subviews.lastObject == overlay);
  self.evidence[@"chromeControlsHiddenAtOpen"] = @(state && ![state[@"chromeControls"] boolValue]);
}
- (void)pipPress:(NSWindow*)window at:(NSPoint)p to:(NSPoint)end flags:(NSEventModifierFlags)flags {
  NSTimeInterval time = NSProcessInfo.processInfo.systemUptime - 2;
  [self pipMouse:NSEventTypeLeftMouseDown window:window screen:p flags:flags time:time];
  if (!NSEqualPoints(p, end)) {
    [self pipMouse:NSEventTypeLeftMouseDragged window:window screen:NSMakePoint((p.x+end.x)/2, (p.y+end.y)/2) flags:flags time:time+0.3];
    [self pipMouse:NSEventTypeLeftMouseDragged window:window screen:end flags:flags time:time+0.6];
  }
  [self pipMouse:NSEventTypeLeftMouseUp window:window screen:end flags:flags time:time+0.8];
}
- (void)pipCheckOverlay:(NSWindow*)window {
  AircTab* tab = self.tabs[0];
  AircTestPipOverlay* overlay = tab.pictureInPictureState[@"appOverlay"];
  if (![overlay isKindOfClass:AircTestPipOverlay.class]) { [tab exitPictureInPicture]; [self finish:@"app overlay missing on reentry"]; return; }
  NSPoint centre = NSMakePoint(NSWidth(window.frame)/2, NSHeight(window.frame)/2);
  NSEvent* move = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:centre modifierFlags:0
      timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
      eventNumber:2 clickCount:0 pressure:0];
  window.acceptsMouseMovedEvents = YES;
  [self pipHoverView:window.contentView event:move];
  [window sendEvent:move];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    NSDictionary* state = tab.pictureInPictureState;
    self.evidence[@"chromeControlsHiddenOnHover"] = @(![state[@"chromeControls"] boolValue] && ![self pipPlaybackControl:window depth:0]);
    self.evidence[@"overlayCapture"] = @(CaptureWindow(window, [self nativePath:@"pip-overlay.png"]));
    NSRect control = [window convertRectToScreen:[overlay.control convertRect:overlay.control.bounds toView:nil]];
    NSPoint p = NSMakePoint(NSMidX(control), NSMidY(control));
    NSRect before = window.frame;
    self.evidence[@"beforeControlActive"] = @(NSApp.active);
    [self pipPress:window at:p to:p flags:0];
    self.evidence[@"overlayClick"] = @(overlay.control.downs == 1 && overlay.control.ups == 1 && NSEqualRects(before, window.frame));
    // A drag that starts on a control stays with it (a scrubber), the window holds still.
    [self pipPress:window at:p to:NSMakePoint(p.x+60, p.y) flags:0];
    self.evidence[@"overlayControlDrag"] = @(overlay.control.downs == 2 && overlay.control.drags >= 2 && overlay.control.ups == 2 &&
                                             NSEqualRects(before, window.frame));
    // The overlay's own background moves the window (⌘: free placement) and never
    // reaches Chromium or the overlay as a click.
    NSPoint band = NSMakePoint(NSMinX(window.frame)+40, NSMaxY(window.frame)-24);
    [self pipPress:window at:band to:band flags:0];
    [self pipPress:window at:band to:NSMakePoint(band.x-50, band.y-30) flags:NSEventModifierFlagCommand];
    self.evidence[@"overlayBandDrag"] = @(fabs(NSMinX(window.frame)-(NSMinX(before)-50)) < 2 && fabs(NSMinY(window.frame)-(NSMinY(before)-30)) < 2);
    self.evidence[@"overlayBandClickSwallowed"] = @(overlay.backgroundPresses == 0);
    self.evidence[@"afterControlActive"] = @(NSApp.active);
    self.evidence[@"overlayCounts"] = @{@"downs": @(overlay.control.downs), @"drags": @(overlay.control.drags), @"ups": @(overlay.control.ups),
                                        @"background": @(overlay.backgroundPresses)};
    [tab exitPictureInPicture];
    for (NSString* check in @[@"overlayInstalled", @"chromeControlsHiddenAtOpen", @"chromeControlsHiddenOnHover", @"overlayClick",
                              @"overlayControlDrag", @"overlayBandDrag", @"overlayBandClickSwallowed"])
      if (![self.evidence[check] boolValue]) { [self finish:[@"overlay assertion: " stringByAppendingString:check]]; return; }
    if ([self.evidence[@"beforeControlActive"] boolValue] || [self.evidence[@"afterControlActive"] boolValue] || NSApp.active) {
      [self finish:@"overlay controls activated the app"]; return;
    }
    [self finish:nil];
  });
}

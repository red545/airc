// Copyright 2026 The Airc Authors
// SPDX-License-Identifier: Apache-2.0
// Minimal AppKit host of the ported ArdiaCore window/tab ownership pattern.
#import <AppKit/AppKit.h>
#import "Airc.h"
#include <dlfcn.h>
#include <cmath>

// Resolve the legacy capture symbol at runtime: newer SDKs mark it unavailable.
// Capture only this host window, never the desktop or another application.
static BOOL CaptureWindow(NSWindow* window, NSString* path) {
  using Capture = CGImageRef (*)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);
  auto capture = reinterpret_cast<Capture>(dlsym(RTLD_DEFAULT, "CGWindowListCreateImage"));
  if (!capture) return NO;
  CGImageRef image = capture(CGRectNull, kCGWindowListOptionIncludingWindow,
      (CGWindowID)window.windowNumber, kCGWindowImageBoundsIgnoreFraming);
  if (!image) return NO;
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:image];
  CGImageRelease(image);
  return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
      writeToFile:path atomically:YES];
}

static NSString* Flag(NSString* key) {
  NSString* prefix = [key stringByAppendingString:@"="];
  for (NSString* arg in NSProcessInfo.processInfo.arguments)
    if ([arg hasPrefix:prefix]) return [arg substringFromIndex:prefix.length];
  return nil;
}

#include "pip_overlay_view.inc"

@interface Host : NSObject <AircEngineDelegate, AircWindowDelegate, AircTabDelegate, NSApplicationDelegate>
@property NSArray* passwordRows;
@property NSInteger oldPasswordIndex;
@property NSInteger cancelledCloses;
@property NSInteger completedCloses;
@property AircWindow* browserWindow;
@property AircWindow* secondWindow;
@property NSMutableArray<NSView*>* featurePanes;
@property NSMutableArray* featureCosts;
@property NSMutableArray* featureRoutes;
@property AircTab* featurePeek;
@property NSMutableArray<AircTab*>* tabs;
@property NSView* page;
@property NSInteger selected;
@property NSString* dataDirectory;
@property NSMutableDictionary* evidence;
@property NSInteger insertionCallbacks;
@property NSMutableArray<AircProfile*>* testProfiles;
@property NSMutableDictionary* profileLoadMilliseconds;
@end
@implementation Host
- (void)engine:(AircEngine*)engine childProcessGone:(NSString*)type status:(int)status exitCode:(int)code {
  if (!Flag(@"--airc-childprocs")) return;
  NSLog(@"CHILDPROCS gone %@ status=%d code=%d", type, status, code);
}

- (void)engineDidStart {
  if (Flag(@"--airc-childprocs")) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      if ([Flag(@"--airc-childprocs") isEqual:@"gpu"])
        [self.tabs[0] loadURL:@"chrome://gpucrash" userInitiated:YES];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      NSLog(@"CHILDPROCS normal quit");
      [AircEngine.sharedEngine quit];
    });
  }
  NSApp.delegate = self;
  self.dataDirectory = Flag(@"--user-data-dir");
  if (Flag(@"--airc-pid")) {
    [[NSString stringWithFormat:@"%d", NSProcessInfo.processInfo.processIdentifier]
        writeToFile:Flag(@"--airc-pid") atomically:YES encoding:NSUTF8StringEncoding error:nil];
  }
  if (Flag(@"--airc-smoke")) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 95 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [self finish:@"acceptance deadline exceeded"];
    });
  }
  self.tabs = [NSMutableArray array];
  self.evidence = [NSMutableDictionary dictionary];
  self.profileLoadMilliseconds = [NSMutableDictionary dictionary];
  if ([Flag(@"--airc-smoke") isEqual:@"native"]) {
    NSDictionary* session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    self.evidence[@"screenLocked"] = session ? @([session[@"CGSSessionScreenIsLocked"] boolValue]) : @YES;
    if ([self.evidence[@"screenLocked"] boolValue]) {
      [self finish:@"screen locked: native qualification not attempted"]; return;
    }
  }
  NSWindow* native = [[NSWindow alloc] initWithContentRect:(([Flag(@"--airc-smoke") isEqual:@"native"] || [Flag(@"--airc-smoke") isEqual:@"dialogs"]) ? NSMakeRect(120,120,760,540) : NSMakeRect(120,120,1200,760))
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
      backing:NSBackingStoreBuffered defer:NO];
  native.releasedWhenClosed = NO;
  if ([Flag(@"--airc-smoke") isEqual:@"dialogs"])
    native.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
  self.browserWindow = [[AircWindow alloc] initWithWindow:native hostView:native.contentView];
  self.browserWindow.delegate = self;
  self.browserWindow.window.title = @"Airc — two-profile engine spike";
  NSView* root = self.browserWindow.hostView;
  self.page = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, root.bounds.size.width, root.bounds.size.height - 48)];
  self.page.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [root addSubview:self.page];
  NSArray* titles = @[@"Profile One", @"Profile Two", @"Back", @"Reload", @"Quit"];
  NSArray* actions = @[@"first:", @"second:", @"back:", @"reload:", @"quit:"];
  for (NSUInteger i = 0; i < titles.count; ++i) {
    NSButton* button = [NSButton buttonWithTitle:titles[i] target:self action:NSSelectorFromString(actions[i])];
    button.frame = NSMakeRect(12 + i * 145, root.bounds.size.height - 40, 138, 30);
    button.autoresizingMask = NSViewMinYMargin;
    [root addSubview:button];
  }
  AircEngine* engine = AircEngine.sharedEngine;
  if (Flag(@"--airc-workload")) {
    self.testProfiles = [NSMutableArray array];
    [self loadWorkloadProfile:0]; return;
  }
  if (Flag(@"--airc-empty-profiles")) {
    [self loadEmptyProfiles:Flag(@"--airc-empty-profiles").intValue];
    return;
  }
  CFAbsoluteTime loadOneStart = CFAbsoluteTimeGetCurrent();
  [engine loadProfile:@"Profile One" completion:^(AircProfile* one) {
    self.profileLoadMilliseconds[@"one"] = @((CFAbsoluteTimeGetCurrent() - loadOneStart) * 1000);
    CFAbsoluteTime loadTwoStart = CFAbsoluteTimeGetCurrent();
    [engine loadProfile:@"Profile Two" completion:^(AircProfile* two) {
      self.profileLoadMilliseconds[@"two"] = @((CFAbsoluteTimeGetCurrent() - loadTwoStart) * 1000);
      if (!one || !two) { [self finish:@"profile load failed"]; return; }
      NSDictionary* saved = [NSDictionary dictionaryWithContentsOfFile:[self.dataDirectory stringByAppendingPathComponent:@"spike-tabs.plist"]];
      for (AircProfile* profile in @[one, two]) {
        BOOL restoring = [Flag(@"--airc-smoke") isEqualToString:@"read"];
        NSString* url = restoring ? saved[profile.name] : (Flag(@"--airc-test-url") ?: saved[profile.name]);
        if (restoring && !url) { [self finish:@"missing persisted tab URL"]; return; }
        if (!url) url = profile == one ? @"https://accounts.google.com/ServiceLogin?service=mail"
                                      : @"https://accounts.google.com/ServiceLogin?service=cl";
        AircTab* tab = [self.browserWindow openTab:url profile:profile foreground:NO];
        if (!tab) { [self finish:@"tab creation failed"]; return; }
        tab.delegate = self;
        [self.tabs addObject:tab];
      }
      [self select:0];
      [self.browserWindow showInactive];
      if ([Flag(@"--airc-smoke") isEqualToString:@"extension"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self extensionTest]; });
      } else if (Flag(@"--airc-smoke")) [self smokeWhenReady:0];
      else if (Flag(@"--airc-screenshot")) {
        [self captureWhenReady:0];
      }
    }];
  }];
}
- (void)loadWorkloadProfile:(int)index {
  NSDictionary* workload = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:Flag(@"--airc-workload")] options:0 error:nil];
  NSArray* names = workload[@"profiles"];
  if (index < names.count) {
    [AircEngine.sharedEngine loadProfile:names[index] completion:^(AircProfile* profile) {
      [self.testProfiles addObject:profile];
      [self.browserWindow prepareProfile:profile];
      [self loadWorkloadProfile:index + 1];
    }]; return;
  }
  for (NSDictionary* entry in workload[@"tabs"]) {
    if (!Flag(@"--airc-load-all") && ![entry[@"recent"] boolValue]) continue;
    int profile = [workload[@"spaces"][[entry[@"space"] integerValue]][@"profile"] intValue];
    AircTab* tab = [self.browserWindow openTab:entry[@"url"] profile:self.testProfiles[profile] foreground:NO];
    [self.tabs addObject:tab];
  }
  if (self.tabs.count) [self select:0];
  [self.browserWindow showInactive];
  [@"ready" writeToFile:Flag(@"--airc-ready") atomically:YES encoding:NSUTF8StringEncoding error:nil];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 600 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [AircEngine.sharedEngine quit]; });
  if (Flag(@"--airc-leak")) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 75 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self leakCycle:0]; });
  }
}
- (void)leakCycle:(int)count {
  if (count == 100) {
    [@"100 real tabs closed" writeToFile:Flag(@"--airc-leak") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return;
  }
  @autoreleasepool {
    AircTab* tab = [self.browserWindow openTab:@"about:blank" profile:self.testProfiles[0] foreground:NO];
    if (!tab) { [self finish:@"leak tab creation failed"]; return; }
    [tab close];
  }
  // Allow asynchronous close and renderer cleanup between cycles.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self leakCycle:count + 1]; });
}
// No tabs or spare renderers; Browsers retain the loaded profiles (D1).
- (void)loadEmptyProfiles:(int)remaining {
  if (!remaining) {
    [@"ready" writeToFile:Flag(@"--airc-ready") atomically:YES encoding:NSUTF8StringEncoding error:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [AircEngine.sharedEngine quit];
    });
    return;
  }
  [AircEngine.sharedEngine loadProfile:[NSString stringWithFormat:@"Empty %d", remaining]
      completion:^(AircProfile* profile) {
    if (!profile) { [self finish:@"empty profile failed"]; return; }
    [self.browserWindow prepareProfile:profile];
    [self loadEmptyProfiles:remaining - 1];
  }];
}
- (void)select:(NSInteger)index {
  if (index >= (NSInteger)self.tabs.count) return;
  for (AircTab* tab in self.tabs) [tab detachFromHost];
  self.selected = index;
  AircTab* tab = self.tabs[index];
  [self.browserWindow activateTab:tab];
  [tab attachToView:self.page];
}
- (void)captureWhenReady:(int)attempt {
  if (attempt > 120) { NSLog(@"Google capture: navigation timeout"); [AircEngine.sharedEngine quit]; return; }
  for (AircTab* tab in self.tabs) {
    if (tab.loading || !tab.title.length) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self captureWhenReady:attempt + 1];
      });
      return;
    }
  }
  // Snapshot background windows only after their documents and view sizes settle.
  [self select:0]; [self select:1]; [self showBoth];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    CaptureWindow(self.browserWindow.window, Flag(@"--airc-screenshot"));
    [AircEngine.sharedEngine quit];
  });
}
- (void)showBoth {
  for (NSView* view in self.page.subviews.copy) [view removeFromSuperview];
  for (NSUInteger i = 0; i < self.tabs.count; ++i) {
    NSView* pane = [[NSView alloc] initWithFrame:NSMakeRect(i * self.page.bounds.size.width / 2, 0,
        self.page.bounds.size.width / 2, self.page.bounds.size.height)];
    pane.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.page addSubview:pane];
    [self.tabs[i] attachToView:pane];
  }
}
- (void)first:(id)sender { [self select:0]; }
- (void)second:(id)sender { [self select:1]; }
- (void)back:(id)sender { [self.tabs[self.selected] goBack]; }
- (void)reload:(id)sender { [self.tabs[self.selected] reload]; }
- (void)quit:(id)sender { [AircEngine.sharedEngine quit]; }
- (void)tabDidChangeURL:(AircTab*)tab {
  NSMutableDictionary* saved = [NSMutableDictionary dictionary];
  for (AircTab* item in self.tabs) saved[item.profile.name] = item.url;
  [saved writeToFile:[self.dataDirectory stringByAppendingPathComponent:@"spike-tabs.plist"] atomically:YES];
}
- (void)smokeWhenReady:(int)attempt {
  if (attempt > 120) { [self finish:@"navigation timeout"]; return; }
  for (AircTab* tab in self.tabs) {
    if (tab.loading || ![tab.url hasPrefix:Flag(@"--airc-test-url")]) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self smokeWhenReady:attempt + 1]; });
      return;
    }
  }
  if (self.insertionCallbacks) { [self finish:@"host open echoed didInsertTab"]; return; }
  if ([Flag(@"--airc-smoke") isEqualToString:@"synthetic-extension"]) { [self syntheticExtension]; return; }
  if ([Flag(@"--airc-smoke") isEqualToString:@"features"]) { [self featuresStart]; return; }
  if ([Flag(@"--airc-smoke") isEqualToString:@"dialogs"]) { [self dialogStep:0 attempt:0]; return; }
  if ([Flag(@"--airc-smoke") isEqual:@"pass13"]) { [self p13:0 attempt:0]; return; }
  if ([Flag(@"--airc-smoke") isEqual:@"pass13-read"]) { [self p13:13 attempt:0]; return; }
  if ([Flag(@"--airc-smoke") isEqual:@"pass12"]) { [self p12:0]; return; }
  if ([Flag(@"--airc-smoke") isEqualToString:@"autofill"]) { [self autofillForm:0 field:0 attempt:0]; return; }
  if ([Flag(@"--airc-smoke") isEqualToString:@"forms"]) { [self formStep:0 attempt:0]; return; }
  if ([Flag(@"--airc-smoke") isEqualToString:@"video"]) { [self videoStep:0]; return; }
  if ([Flag(@"--airc-smoke") isEqualToString:@"devtools"]) { [self devtoolsTest]; return; }
  if ([Flag(@"--airc-smoke") isEqualToString:@"download"]) { [self downloadTest]; return; }
  if ([Flag(@"--airc-smoke") isEqualToString:@"surfaces"]) { [self surfaceStep:0]; return; }
  if ([Flag(@"--airc-smoke") isEqualToString:@"native"]) { [self nativeStep:0 attempt:0]; return; }
  if ([Flag(@"--airc-smoke") isEqualToString:@"imports"]) { [self importsTest]; return; }
  if ([Flag(@"--airc-smoke") isEqualToString:@"services"]) { [self servicesTest]; return; }
  if ([Flag(@"--airc-smoke") isEqualToString:@"hosting"]) { [self hostingTest]; return; }
  if ([Flag(@"--airc-smoke") isEqualToString:@"memory"]) { [self memoryTest]; return; }
  if ([Flag(@"--airc-smoke") isEqual:@"discardcrash"]) { [self discardCrash:0]; return; }
  [self checkTab:0];
}
#include "discard_checks.inc"
#include "features_checks.inc"
#include "pass12_checks.inc"
#include "pass13_checks.inc"
- (void)autofillForm:(int)form field:(NSUInteger)index attempt:(int)attempt {
  [self select:0]; AircTab* tab = self.tabs[0];
  if (attempt > 60) { [self finish:[NSString stringWithFormat:@"autofill form %d field %lu timed out",form,(unsigned long)index]]; return; }
  NSArray* fields = form == 0 ? @[@"given-name",@"family-name",@"street-address",@"address-level2",@"address-level1",@"postal-code",@"country"] : @[@"cc-name",@"cc-number",@"cc-exp-month",@"cc-exp-year"];
  NSArray* values = form == 0 ? @[@"Airc",@"Fixture",@"123 Example Street",@"Mountain View",@"CA",@"94043",@"US"] : @[@"Airc Fixture",@"4111111111111111",@"12",@"2030"];
  if (tab.loading) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ [self autofillForm:form field:index attempt:attempt+1]; }); return;
  }
  if (index < fields.count) {
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":[NSString stringWithFormat:@"document.getElementById('%@').focus()",fields[index]], @"userGesture":@YES} timeout:5 completion:^(NSDictionary* r, NSString* e) {
      [tab devToolsCall:@"Input.insertText" params:@{@"text":values[index]} timeout:5 completion:^(NSDictionary* r, NSString* e) {
        if (e) { [self finish:e]; return; }
        [self autofillForm:form field:index+1 attempt:0];
      }];
    }]; return;
  }
  if (index == fields.count) {
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"document.getElementById('submit').click()",@"userGesture":@YES} timeout:5 completion:^(NSDictionary* r, NSString* e) { [self autofillForm:form field:index+1 attempt:0]; }]; return;
  }
  NSDictionary* prompt = tab.autofillPrompt;
  if (prompt) {
    self.evidence[form == 0 ? @"addressPrompt" : @"cardPrompt"] = prompt;
    [tab resolveAutofillPrompt:[prompt[@"id"] integerValue] action:@"accept"];
    if (form == 1) { [self finish:nil]; return; }
    [tab loadURL:[Flag(@"--airc-test-url") stringByAppendingString:@"card"] userInitiated:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ [self autofillForm:1 field:0 attempt:0]; }); return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ [self autofillForm:form field:index attempt:attempt+1]; });
}
// Real renderer form submission, only synthetic values, never owner credentials.
- (void)formStep:(int)step attempt:(int)attempt {
  AircTab* tab = self.tabs[0];
  [self select:0];
  if (attempt > 40) { [self finish:[NSString stringWithFormat:@"forms step %d timed out", step]]; return; }
  if (step == 0 || step == 2) {
    NSString* field = step == 0 ? @"username" : @"password";
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":[NSString stringWithFormat:@"document.getElementById('%@').focus()",field], @"userGesture":@YES} timeout:5 completion:^(NSDictionary* r, NSString* e) {
      [self formStep:step+1 attempt:0];
    }]; return;
  }
  if (step == 1 || step == 3) {
    [tab devToolsCall:@"Input.insertText" params:@{@"text": step == 1 ? @"airc-synthetic" : @"Only-A-Fixture-42!"} timeout:5 completion:^(NSDictionary* r, NSString* e) {
      if (e) { [self finish:e]; return; }
      [self formStep:step+1 attempt:0];
    }]; return;
  }
  if (step == 4) {
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"document.getElementById('submit').click()", @"userGesture":@YES} timeout:5 completion:^(NSDictionary* r, NSString* e) {
      [self formStep:5 attempt:0];
    }]; return;
  }
  if (step == 5) {
    NSDictionary* prompt = tab.passwordPrompt;
    if ([prompt[@"state"] isEqual:@"save"]) {
      self.evidence[@"passwordPrompt"] = prompt;
      [tab resolvePasswordPrompt:@"save" username:nil password:nil];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [tab loadURL:Flag(@"--airc-test-url") userInitiated:YES];
        [self formStep:6 attempt:0];
      }); return;
    }
  }
  if (step == 6 && !tab.loading && ![tab.url containsString:@"submitted"]) {
    // A trusted user gesture reveals password values to page script. Read only
    // boolean equality, never record the password in the report.
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"document.body.click();document.getElementById('username').value==='airc-synthetic' && document.getElementById('password').value==='Only-A-Fixture-42!'", @"userGesture":@YES, @"returnByValue":@YES} timeout:5 completion:^(NSDictionary* r, NSString* e) {
      if ([r[@"result"][@"value"] boolValue]) {
        self.evidence[@"passwordFilled"] = @YES;
        [self formStep:7 attempt:0];
      } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self formStep:6 attempt:attempt+1]; });
      }
    }]; return;
  }
  if (step == 7) {
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"document.getElementById('upload').click()", @"userGesture":@YES} timeout:5 completion:^(NSDictionary* r, NSString* e) {
      [self formStep:8 attempt:0];
    }]; return;
  }
  if (step == 8) {
    NSWindow* sheet = self.browserWindow.window.attachedSheet;
    if ([sheet isKindOfClass:NSOpenPanel.class]) {
      self.evidence[@"uploadSheetParent"] = @(sheet.sheetParent == self.browserWindow.window);
      [(NSOpenPanel*)sheet cancel:nil];
      [self formStep:9 attempt:0]; return;
    }
  }
  if (step == 9) {
    [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"window.fileCancelled===true && document.getElementById('upload').files.length===0", @"returnByValue":@YES} timeout:5 completion:^(NSDictionary* r, NSString* e) {
      if ([r[@"result"][@"value"] boolValue]) {
        self.evidence[@"uploadCancel"] = @YES; [self finish:nil];
      } else {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self formStep:9 attempt:attempt+1]; });
      }
    }]; return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self formStep:step attempt:attempt+1]; });
}
- (void)videoStep:(int)step {
  [self select:0];
  NSArray* scripts = @[
    @"(async()=>{window.c=document.createElement('canvas');c.width=320;c.height=180;const g=c.getContext('2d');window.draw=setInterval(()=>{g.fillStyle='blue';g.fillRect(0,0,320,180)},30);window.v=document.createElement('video');v.muted=true;v.srcObject=c.captureStream(10);document.body.append(v);await v.play();return true})()",
    @"v.requestFullscreen().then(()=>document.fullscreenElement===v)",
    @"document.exitFullscreen().then(()=>document.fullscreenElement===null)",
    @"v.requestPictureInPicture().then(()=>document.pictureInPictureElement===v)",
    @"document.exitPictureInPicture().then(()=>{clearInterval(draw);v.srcObject.getTracks().forEach(t=>t.stop());return document.pictureInPictureElement===null})"
  ];
  if (step == scripts.count) {
    BOOL ok = YES;
    for (int i=0; i<scripts.count; ++i) ok &= [self.evidence[[NSString stringWithFormat:@"video-%d",i]] isEqual:@YES];
    [self finish:ok ? nil : @"video surface transition failed"]; return;
  }
  [self.tabs[0] devToolsCall:@"Runtime.evaluate" params:@{@"expression":scripts[step], @"userGesture":@YES, @"awaitPromise":@YES, @"returnByValue":@YES} timeout:8 completion:^(NSDictionary* r, NSString* e) {
    self.evidence[[NSString stringWithFormat:@"video-%d",step]] = e ?: (r[@"result"][@"value"] ?: r);
    [self videoStep:step+1];
  }];
}
- (BOOL)window:(AircWindow*)window preHandleKeyEvent:(NSEvent*)event {
  if ((event.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagOption)) ==
      (NSEventModifierFlagCommand|NSEventModifierFlagOption) && [event.charactersIgnoringModifiers.lowercaseString isEqual:@"i"]) {
    self.evidence[@"devtoolsShortcut"] = @YES;
    [self.tabs[self.selected] showDevTools]; return YES;
  }
  return NO;
}
- (void)devtoolsTest {
  [self select:0]; [self.tabs[0] focus];
  NSWindow* window = self.browserWindow.window;
  NSEvent* key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint
      modifierFlags:NSEventModifierFlagCommand|NSEventModifierFlagOption
      timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
      characters:@"i" charactersIgnoringModifiers:@"i" isARepeat:NO keyCode:34];
  [window sendEvent:key];
  [self devtoolsVerify:0];
}
- (void)devtoolsVerify:(int)attempt {
  NSView* view = self.tabs[0].devToolsView;
  if (!view) {
    if (attempt > 100) { [self finish:@"DevTools view missing after shortcut"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self devtoolsVerify:attempt+1]; });
    return;
  }
  view.frame = NSMakeRect(0,0,600,300);
  [self.page addSubview:view];
  self.evidence[@"devtoolsAttached"] = @(view.window == self.browserWindow.window);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    self.evidence[@"devtoolsCapture"] = @(CaptureWindow(self.browserWindow.window, Flag(@"--airc-screenshot")));
    [view removeFromSuperview]; [self.tabs[0] closeDevTools];
    [self finish:[self.evidence[@"devtoolsShortcut"] boolValue] ? nil : @"shortcut not handled"];
  });
}
- (void)downloadTest {
  [self select:0];
  __weak Host* weakSelf = self;
  [self.tabs[0].profile observeDownloads:^(NSDictionary* download) {
    Host* host = weakSelf;
    host.evidence[@"download"] = download;
    host.evidence[@"progressEvents"] = @([host.evidence[@"progressEvents"] intValue] + 1);
    if ([download[@"state"] intValue] == 1) {
      NSString* contents = [NSString stringWithContentsOfFile:download[@"path"] encoding:NSUTF8StringEncoding error:nil];
      BOOL ok = [contents isEqual:@"Airc download fixture\n"] && [download[@"received"] intValue] == 22;
      dispatch_async(dispatch_get_main_queue(), ^{
        [host.tabs[0].profile observeDownloads:nil];
        [host finish:ok ? nil : @"saved download mismatch"];
      });
    }
  }];
  [self.tabs[0] loadURL:[Flag(@"--airc-test-url") stringByAppendingString:@"download"] userInitiated:YES];
}
- (void)surfaceStep:(int)step {
  [self select:0];
  self.browserWindow.uiAnchorView = self.browserWindow.hostView;
  self.browserWindow.uiAnchorRect = NSMakeRect(14, self.browserWindow.hostView.bounds.size.height - 40, 180, 30);
  NSArray* scripts = @[
    @"navigator.mediaDevices.getUserMedia({video:true}).then(s=>{s.getTracks().forEach(t=>t.stop());return 'granted'},e=>e.name)",
    @"navigator.mediaDevices.getUserMedia({audio:true}).then(s=>{s.getTracks().forEach(t=>t.stop());return 'granted'},e=>e.name)",
    @"new Promise(r=>navigator.geolocation.getCurrentPosition(()=>r('granted'),e=>r(e.code),{timeout:3000}))",
    @"Notification.requestPermission()",
    @"(()=>{document.body.innerHTML='<a style=display:block;padding:30px href=https://space.example.test/>Space link</a>';return true})()"
  ];
  if (step >= scripts.count) {
    [self.tabs[0] devToolsCall:@"Input.dispatchMouseEvent" params:@{@"type":@"mousePressed", @"x":@40, @"y":@40, @"button":@"right", @"clickCount":@1} timeout:5 completion:^(NSDictionary* r, NSString* e) {
      [self.tabs[0] devToolsCall:@"Input.dispatchMouseEvent" params:@{@"type":@"mouseReleased", @"x":@40, @"y":@40, @"button":@"right", @"clickCount":@1} timeout:5 completion:^(NSDictionary* r, NSString* e) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          BOOL ok = self.evidence[@"spaceLink"] != nil &&
              [self.evidence[@"surface-0"] isEqual:@"NotAllowedError"] &&
              [self.evidence[@"surface-1"] isEqual:@"NotAllowedError"] &&
              [self.evidence[@"surface-2"] isEqual:@1] &&
              [self.evidence[@"surface-3"] isEqual:@"denied"];
          for (NSString* kind in @[@"camera", @"microphone", @"location", @"notifications"]) {
            ok &= [self.evidence[kind][@"correctProfile"] boolValue];
            ok &= [self.evidence[kind][@"anchor"] isEqual:NSStringFromRect(self.browserWindow.uiAnchorRectInScreen)];
          }
          [self finish:ok ? nil : @"permission or context submenu assertion failed"];
        });
      }];
    }];
    return;
  }
  [self.tabs[0] devToolsCall:@"Runtime.evaluate" params:@{@"expression":scripts[step], @"userGesture":@YES, @"awaitPromise":@YES, @"returnByValue":@YES} timeout:8 completion:^(NSDictionary* r, NSString* e) {
    self.evidence[[NSString stringWithFormat:@"surface-%d",step]] = e ?: (r[@"result"][@"value"] ?: r);
    [self surfaceStep:step+1];
  }];
}
- (NSArray*)tab:(AircTab*)tab spacesForContextMenuLink:(NSString*)url {
  return @[@{@"id":@"space-two", @"title":@"Space Two"}];
}
- (void)tab:(AircTab*)tab openContextMenuLink:(NSString*)url inSpace:(NSString*)spaceID {
  self.evidence[@"spaceLink"] = @{@"url":url, @"space":spaceID};
}
- (NSDictionary*)tab:(AircTab*)tab runContextMenu:(NSDictionary*)menu {
  self.evidence[@"contextMenu"] = menu;
  for (NSDictionary* item in menu[@"items"]) {
    if ([item[@"label"] isEqual:@"Open link in Space"]) {
      return @{@"command":item[@"submenu"][0][@"id"]};
    }
  }
  return nil;
}
#include "native_checks.inc"
#include "dialog_checks.inc"
#include "pip_window_checks.inc"
#include "pip_checks.inc"

- (void)importsTest {
  AircProfile* profile = self.tabs[0].profile;
  NSDictionary* login = @{@"origin": @"https://import.example.test/login", @"signonRealm": @"https://import.example.test/",
      @"username": @"synthetic-user", @"password": @"synthetic-password"};
  NSMutableDictionary* duplicate = [login mutableCopy]; duplicate[@"password"] = @"must-not-overwrite";
  [profile importLogins:@[login, duplicate, @{@"origin": @"file:///bad"}] completion:^(NSDictionary* first) {
    self.evidence[@"first"] = first;
    [profile importLogins:@[login] completion:^(NSDictionary* second) {
      self.evidence[@"second"] = second;
      NSDictionary* cookie = @{@"host": @"127.0.0.1", @"name": @"synthetic", @"value": @"fixture", @"path": @"/",
          @"expiresUTC": @0, @"secure": @NO, @"httpOnly": @NO, @"sameSite": @1};
      NSMutableArray* cookies = [NSMutableArray arrayWithObject:cookie];
      for (NSDictionary* change in @[@{@"host": @"bad/path"}, @{@"sameSite": @0}, @{@"expiresUTC": @1},
                                     @{@"name": @"__Secure-bad"}, @{@"metadata": @{@"partition_key": @"https://example.test"}}]) {
        NSMutableDictionary* row = [cookie mutableCopy]; [row addEntriesFromDictionary:change]; [cookies addObject:row];
      }
      [profile importCookies:cookies completion:^(NSDictionary* result) {
        self.evidence[@"cookies"] = result;
        [self cleanupTest:0];
      }];
    }];
  }];
}
- (void)cleanupTest:(NSUInteger)index {
  NSArray* names = @[@"Default", @"Profile One", @"profile one", @"../outside", @"Cleanup Link", @"Cleanup Fixture"];
  if (index == 0) {
    NSString* folder = [self.dataDirectory stringByAppendingPathComponent:@"Cleanup Fixture"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [@"{}" writeToFile:[folder stringByAppendingPathComponent:@"Preferences"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager createSymbolicLinkAtPath:[self.dataDirectory stringByAppendingPathComponent:@"Cleanup Link"]
        withDestinationPath:folder error:nil];
    self.evidence[@"cleanup"] = [NSMutableArray array];
  }
  if (index == names.count) {
    BOOL ok = [self.evidence[@"first"][@"saved"] intValue] == 1 &&
        [self.evidence[@"first"][@"skipped"] intValue] == 1 &&
        [self.evidence[@"first"][@"rejected"] intValue] == 1 &&
        [self.evidence[@"second"][@"skipped"] intValue] == 1 &&
        [self.evidence[@"cookies"][@"accepted"] intValue] == 1 &&
        [self.evidence[@"cookies"][@"rejected"] intValue] == 5;
    for (NSDictionary* row in self.evidence[@"cookies"][@"results"])
      if ([row[@"status"] isEqual:@"rejected"]) ok &= [row[@"reason"] length] > 0;
    for (NSUInteger i = 0; i < names.count; ++i)
      ok &= [self.evidence[@"cleanup"][i][@"deleted"] boolValue] == (i == names.count - 1);
    ok &= ![NSFileManager.defaultManager fileExistsAtPath:[self.dataDirectory stringByAppendingPathComponent:@"Cleanup Fixture"]];
    [self finish:ok ? nil : @"import/cleanup assertions failed"]; return;
  }
  [AircEngine.sharedEngine deleteUnloadedProfileDirectory:names[index] completion:^(NSDictionary* result) {
    [self.evidence[@"cleanup"] addObject:result];
    [self cleanupTest:index + 1];
  }];
}
- (void)servicesTest {
  AircProfile* profile = self.tabs[0].profile;
  __weak Host* weakSelf = self;
  [profile observeHistoryVisits:^(NSDictionary* visit) { weakSelf.evidence[@"visit"] = visit; }];
  self.evidence[@"googleAccounts"] = profile.googleAccounts;
  [profile importLogins:@[@{@"origin": @"https://import.example.test/login", @"signonRealm": @"https://import.example.test/",
      @"actionURL": @"https://import.example.test/submit", @"username": @"synthetic-user", @"password": @"synthetic-password"},
      @{@"origin": @"file:///invalid", @"password": @"invalid"}]
      completion:^(NSDictionary* result) {
    self.evidence[@"loginImport"] = result;
    [profile importCookies:@[@{@"host": @"127.0.0.1", @"name": @"imported", @"value": @"synthetic-cookie", @"path": @"/",
      @"expiresUTC": @((int64_t)((NSDate.date.timeIntervalSince1970 + 11644473600 + 86400) * 1000000)),
      @"secure": @NO, @"httpOnly": @NO, @"sameSite": @1}]
      completion:^(NSDictionary* result) {
      self.evidence[@"cookieImport"] = result;
      [self.tabs[0] loadURL:[Flag(@"--airc-test-url") stringByAppendingString:@"history-one"] userInitiated:YES];
      [self servicesVerify:0];
    }];
  }];
}
- (void)servicesVerify:(int)attempt {
  if (!self.evidence[@"visit"] || self.tabs[0].loading) {
    if (attempt > 100) { [self finish:@"history visit missing"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self servicesVerify:attempt + 1]; });
    return;
  }
  [self.tabs[0].profile queryHistory:@"history-one" limit:10 completion:^(NSArray* rows) {
    self.evidence[@"historyOne"] = rows;
    [self.tabs[1].profile queryHistory:@"history-one" limit:10 completion:^(NSArray* rows) {
      self.evidence[@"historyTwo"] = rows;
      NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(150,150,640,480)
          styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
          backing:NSBackingStoreBuffered defer:NO];
      window.releasedWhenClosed = NO;
      self.secondWindow = [[AircWindow alloc] initWithWindow:window hostView:window.contentView];
      [self.secondWindow prepareProfile:self.tabs[0].profile];
      AircTab* tab = [self.secondWindow openTab:Flag(@"--airc-test-url") profile:self.tabs[0].profile foreground:YES];
      [tab attachToView:self.secondWindow.hostView];
      [self.secondWindow showInactive];
      [self secondWindowVerify:tab attempt:0];
    }];
  }];
}
- (void)secondWindowVerify:(AircTab*)tab attempt:(int)attempt {
  if (tab.loading || [tab.url isEqualToString:@"about:blank"]) {
    if (attempt > 100) { [self finish:@"second window navigation timeout"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self secondWindowVerify:tab attempt:attempt + 1]; });
    return;
  }
  [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression": @"document.cookie", @"returnByValue": @YES} timeout:5 completion:^(NSDictionary* result, NSString* error) {
    self.evidence[@"secondWindowCookie"] = result[@"result"][@"value"] ?: @"";
    self.evidence[@"secondWindowAttached"] = @(tab.view.window == self.secondWindow.window);
    [self.tabs[1] devToolsCall:@"Runtime.evaluate" params:@{@"expression": @"document.cookie", @"returnByValue": @YES} timeout:5 completion:^(NSDictionary* result, NSString* error) {
      self.evidence[@"otherProfileCookie"] = result[@"result"][@"value"] ?: @"";
      [tab close]; [self.secondWindow close];
      [self.tabs[0].profile observeHistoryVisits:nil];
      BOOL ok = [self.evidence[@"loginImport"][@"saved"] intValue] == 1 &&
          [self.evidence[@"loginImport"][@"rejected"] intValue] == 1 &&
          [self.evidence[@"cookieImport"][@"accepted"] intValue] == 1 &&
          [self.evidence[@"historyOne"] count] == 1 && [self.evidence[@"historyTwo"] count] == 0 &&
          [self.evidence[@"secondWindowCookie"] isEqual:@"imported=synthetic-cookie"] &&
          [self.evidence[@"otherProfileCookie"] isEqual:@""];
      [self finish:ok ? nil : @"profile services qualification failed"];
    }];
  }];
}
- (void)hostingTest {
  NSMutableArray* unexpected = [NSMutableArray array];
  for (NSWindow* window in NSApp.windows) {
    if (window.visible && window != self.browserWindow.window) [unexpected addObject:window.title ?: @""];
  }
  self.evidence[@"unexpectedStartupWindows"] = unexpected;
  self.evidence[@"applicationActive"] = @(NSApp.active);
  [self select:0];
  AircTab* tab = self.tabs[0];
  NSTextField* sidebar = [[NSTextField alloc] initWithFrame:NSMakeRect(800, 720, 180, 28)];
  [self.browserWindow.hostView addSubview:sidebar];
  [self.browserWindow.window makeFirstResponder:sidebar];
  NSResponder* before = self.browserWindow.window.firstResponder;
  [tab attachToView:self.page];
  self.evidence[@"attachPreservesSidebarFocus"] = @(before == self.browserWindow.window.firstResponder);
  [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"document.querySelector('input').focus()"} timeout:5 completion:^(NSDictionary* result, NSString* error) {
    [tab focus];
    NSWindow* window = self.browserWindow.window;
    NSEvent* key = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
        characters:@"x" charactersIgnoringModifiers:@"x" isARepeat:NO keyCode:7];
    [window sendEvent:key];
    [self waitForTextInput:tab window:window sidebar:sidebar attempt:0];
  }];
}
- (void)waitForTextInput:(AircTab*)tab window:(NSWindow*)window sidebar:(NSTextField*)sidebar attempt:(int)attempt {
    if (![AircPageView isEditingText:(id)window.firstResponder]) {
      if (attempt >= 100) { [self finish:@"native text-input state never arrived"]; return; }
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [self waitForTextInput:tab window:window sidebar:sidebar attempt:attempt + 1];
      });
      return;
    }
    id responder = window.firstResponder;
    self.evidence[@"nativeEditingText"] = @([AircPageView isEditingText:responder]);
    self.evidence[@"nativeTextInputClient"] = @([responder conformsToProtocol:@protocol(NSTextInputClient)]);
    if ([responder conformsToProtocol:@protocol(NSTextInputClient)]) {
      [responder setMarkedText:@"にほん" selectedRange:NSMakeRange(3, 0) replacementRange:NSMakeRange(NSNotFound,0)];
      [responder insertText:@"日本語" replacementRange:NSMakeRange(NSNotFound,0)];
      [responder unmarkText];
    }
    [tab find:@"Local profile isolation fixture" forward:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"document.querySelector('input').value", @"returnByValue":@YES} timeout:5 completion:^(NSDictionary* reply, NSString* failure) {
        self.evidence[@"nativeTypedText"] = reply[@"result"][@"value"] ?: @"";
        self.evidence[@"findState"] = tab.findState;
        [tab stopFinding];
        NSView* parent = tab.view.superview;
        [tab setPageVisible:NO];
        self.evidence[@"hideKeepsParent"] = @(tab.view.hidden && tab.view.superview == parent);
        [tab setPageVisible:YES];
        self.evidence[@"showKeepsParent"] = @(!tab.view.hidden && tab.view.superview == parent);
        [window makeFirstResponder:sidebar];
        [tab detachFromHost];
        self.evidence[@"detachPreservesSidebarFocus"] = @([window.firstResponder isKindOfClass:NSTextView.class]);
        [tab attachToView:self.page];
        if (Flag(@"--airc-screenshot")) CaptureWindow(window, Flag(@"--airc-screenshot"));
        BOOL ok = [self.evidence[@"attachPreservesSidebarFocus"] boolValue] &&
            [self.evidence[@"nativeTypedText"] isEqualToString:@"x日本語"] && [self.evidence[@"findMatches"] intValue] == 1;
        [self finish:ok ? nil : @"hosting input/find qualification failed"];
      }];
    });
}
- (void)tab:(AircTab*)tab didFindMatches:(int)count active:(int)active final:(BOOL)final {
  if (final) self.evidence[@"findMatches"] = @(count);
}
- (void)extensionTest {
  [self select:0];
  [self.tabs[0] devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"(()=>{const b=[...document.querySelectorAll('button')].find(b=>b.innerText.includes('Reject all')||b.innerText.includes('Add to Chrome'));if(!b)return {text:document.body.innerText};b.scrollIntoView({block:'center'});const r=b.getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2,text:b.innerText};})()", @"returnByValue":@YES} timeout:10 completion:^(NSDictionary* reply, NSString* error) {
    NSDictionary* value = reply[@"result"][@"value"] ?: @{};
    self.evidence[@"storeButton"] = value;
    [self.tabs[0] copyPicture:5 completion:^(CGImageRef picture) {
      if (!picture) return;
      NSBitmapImageRep* image = [[NSBitmapImageRep alloc] initWithCGImage:picture];
      [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
        writeToFile:[Flag(@"--airc-report") stringByAppendingString:@".store.png"] atomically:YES];
    }];
    if (!value[@"x"]) { [self finish:@"Web Store install button unavailable"]; return; }
    NSDictionary* press = @{@"type":@"mousePressed", @"button":@"left", @"clickCount":@1, @"x":value[@"x"], @"y":value[@"y"]};
    [self.tabs[0] devToolsCall:@"Input.dispatchMouseEvent" params:press timeout:5 completion:^(NSDictionary* a, NSString* e) {
      NSMutableDictionary* release = [press mutableCopy]; release[@"type"]=@"mouseReleased";
      [self.tabs[0] devToolsCall:@"Input.dispatchMouseEvent" params:release timeout:5 completion:^(NSDictionary* a, NSString* e) {
        if ([value[@"text"] containsString:@"Reject all"]) {
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self extensionTest]; });
        } else [self extensionInstalled:0];
      }];
    }];
  }];
}
- (void)extensionInstalled:(int)attempt {
  NSString* extension = @"ddkjiahejlhfcafbddmgiahcphecmpfh";
  NSArray* first = self.tabs[0].profile.extensions;
  if (![[first valueForKey:@"id"] containsObject:extension]) {
    if (attempt > 50) { self.evidence[@"extensions"] = first; [self finish:@"Web Store install timed out"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self extensionInstalled:attempt+1]; }); return;
  }
  self.evidence[@"installedInOne"] = first;
  self.evidence[@"absentInTwo"] = @(![[self.tabs[1].profile.extensions valueForKey:@"id"] containsObject:extension]);
  self.evidence[@"action"] = [self.tabs[0] actionStatesForExtensions:@[extension]];
  AircTab* popup = [self.browserWindow presentActionPopupForExtension:extension tab:self.tabs[0]
      anchorRect:NSMakeRect(20, self.page.bounds.size.height-30, 25, 25) inView:self.page];
  self.evidence[@"anchoredPopup"] = @(popup != nil);
  if (!popup) { [self finish:@"extension popup did not open"]; return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [popup copyPicture:5 completion:^(CGImageRef picture) {
      BOOL captured = NO;
      if (picture) {
        NSBitmapImageRep* image = [[NSBitmapImageRep alloc] initWithCGImage:picture];
        captured = [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
          writeToFile:[Flag(@"--airc-report") stringByAppendingString:@".popup.png"] atomically:YES];
      }
      [self.browserWindow closeActionPopup];
      [self finish:captured ? nil : @"popup capture failed"];
    }];
  });
}
- (void)memoryTest {
  [self select:1];
  AircTab* tab = self.tabs[1];
  self.evidence[@"visibleRefused"] = @(![tab discard]);
  [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"document.body.style.height='5000px';scrollTo(0,900);document.title='Discard fixture';true", @"returnByValue":@YES} timeout:5 completion:^(NSDictionary* result, NSString* error) {
    if (error) { [self finish:error]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [self select:0];
      self.evidence[@"discardAccepted"] = @([tab discard]);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        self.evidence[@"discarded"] = @(tab.discarded);
        self.evidence[@"titlePreserved"] = @([tab.title isEqualToString:@"Discard fixture"]);
        [self select:1];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"({discarded:document.wasDiscarded,scroll:scrollY})", @"returnByValue":@YES} timeout:5 completion:^(NSDictionary* reply, NSString* failure) {
            self.evidence[@"restored"] = reply[@"result"][@"value"] ?: @{};
            [self testFormProtection];
          }];
        });
      });
    });
  }];
}
- (void)testFormProtection {
  AircTab* tab = self.tabs[1];
  [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"document.body.innerHTML='<input id=edit>';document.querySelector('input').focus()"} timeout:5 completion:^(NSDictionary* result, NSString* error) {
    // Real renderer input, not assigning input.value or dispatching a synthetic DOM event.
    [tab devToolsCall:@"Input.insertText" params:@{@"text":@"unsaved 日本語"} timeout:5 completion:^(NSDictionary* reply, NSString* failure) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self select:0];
        self.evidence[@"formRefused"] = @(![tab discard]);
        tab.profile.unloadTimeout = 0.25;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          self.evidence[@"timeoutProtectsForm"] = @(!tab.discarded);
          // Reload resets the document's edited state, then the next hide arms its deadline.
          [self select:1]; [tab reload];
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self select:0];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
              self.evidence[@"timeoutDiscarded"] = @(tab.discarded);
              BOOL ok = [self.evidence[@"visibleRefused"] boolValue] && [self.evidence[@"discarded"] boolValue] &&
                [self.evidence[@"titlePreserved"] boolValue] && [self.evidence[@"formRefused"] boolValue] &&
                [self.evidence[@"restored"][@"discarded"] boolValue] && [self.evidence[@"timeoutDiscarded"] boolValue];
              if (!ok) { [self finish:@"memory contract failed"]; return; }
              tab.profile.unloadTimeout = 1800;
              [self select:1];
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self testAudioProtection]; });
            });
          });
        });
      });
    }];
  }];
}
- (void)testAudioProtection {
  AircTab* tab = self.tabs[1];
  [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"window.ctx=new AudioContext();window.tone=ctx.createOscillator();tone.connect(ctx.destination);tone.start();ctx.resume()", @"userGesture":@YES, @"awaitPromise":@YES} timeout:5 completion:^(NSDictionary* result, NSString* error) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [self select:0];
      self.evidence[@"audioDetected"] = @(tab.audible);
      self.evidence[@"audioRefused"] = @(![tab discard]);
      [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"tone.stop();ctx.close()", @"awaitPromise":@YES} timeout:5 completion:^(NSDictionary* result, NSString* error) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          // Chromium protects recently audible tabs for a minute. Verify that
          // protection, then use a fresh silent page as the pressure victim.
          self.evidence[@"recentAudioRefused"] = @(![tab discard]);
          AircTab* silent = [self.browserWindow openTab:Flag(@"--airc-test-url") profile:tab.profile foreground:NO];
          [self.tabs addObject:silent];
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            self.evidence[@"pressureInjected"] = @([AircEngine simulateMemoryPressureForTesting:2]);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
              self.evidence[@"pressureDiscardedHidden"] = @(silent.discarded);
              self.evidence[@"pressureProtectedVisible"] = @(!self.tabs[0].discarded);
              BOOL ok = [self.evidence[@"audioDetected"] boolValue] && [self.evidence[@"audioRefused"] boolValue] &&
                  [self.evidence[@"pressureCallback"] boolValue] && silent.discarded && !tab.discarded &&
                  [self.evidence[@"recentAudioRefused"] boolValue] && !self.tabs[0].discarded;
              [self finish:ok ? nil : @"audio or pressure contract failed"];
            });
          });
        });
      }];
    });
  }];
}
- (void)engine:(AircEngine*)engine memoryPressure:(NSInteger)level {
  self.evidence[@"pressureCallback"] = @(level);
}
- (void)checkTab:(NSUInteger)index {
  if (index == self.tabs.count) {
    for (int cycle = 0; cycle < 10; ++cycle) { [self select:0]; [self select:1]; }
    [self.browserWindow deactivateAll];
    [self verifyLiveTab:0];
    return;
  }
  [self select:index];
  AircTab* tab = self.tabs[index];
  NSString* marker = index == 0 ? @"one" : @"two";
  BOOL writing = [Flag(@"--airc-smoke") isEqualToString:@"write"];
  NSString* expression = [NSString stringWithFormat:
    @"(()=>{const marker='%@';%@ window.__aircSwitchMarker=marker;document.body.textContent='Profile '+marker+' — '+document.cookie; return {cookie:document.cookie,storage:localStorage.getItem('profile'),ok:document.cookie==='airc_profile='+marker && localStorage.getItem('profile')===marker};})()",
    marker, writing ? [NSString stringWithFormat:@"if(document.cookie||localStorage.getItem('profile'))throw Error('unexpected existing profile data');document.cookie='airc_profile=%@; Max-Age=86400; Path=/';localStorage.setItem('profile','%@');", marker, marker] : @""];
  [tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":expression, @"returnByValue":@YES} timeout:10
        completion:^(NSDictionary* result, NSString* error) {
    NSDictionary* value = result[@"result"][@"value"];
    if (error || ![value[@"ok"] boolValue]) { [self finish:error ?: @"cookie/storage isolation failed"]; return; }
    self.evidence[marker] = value;
    [self checkTab:index + 1];
  }];
}
- (void)verifyLiveTab:(NSUInteger)index {
  if (index < self.tabs.count) {
    [self select:index];
    [self.tabs[index] devToolsCall:@"Runtime.evaluate"
        params:@{@"expression":@"window.__aircSwitchMarker", @"returnByValue":@YES}
        timeout:10 completion:^(NSDictionary* result, NSString* error) {
      if (error || ![result[@"result"][@"value"] isEqual:index == 0 ? @"one" : @"two"]) {
        [self finish:error ?: @"switch reloaded a page"]; return;
      }
      [self verifyLiveTab:index + 1];
    }];
    return;
  }
  [self showBoth];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    NSString* screenshot = Flag(@"--airc-screenshot");
    NSDictionary* session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    BOOL locked = !session || [session[@"CGSSessionScreenIsLocked"] boolValue];
    if (screenshot && !locked && !CaptureWindow(self.browserWindow.window, screenshot)) {
      [self finish:@"own-window capture failed"]; return;
    }
    [self.tabs[0] copyPicture:5 completion:^(CGImageRef picture) {
      if (!picture) { [self finish:@"renderer surface copy failed"]; return; }
      [self finish:nil];
    }];
  });
}
- (void)finish:(NSString*)error {
  if ([Flag(@"--airc-native-case") isEqual:@"pip"])
    for (AircTab* tab in self.tabs) [tab exitPictureInPicture];
  NSString* report = Flag(@"--airc-report");
  if (report) {
    NSData* data = [NSJSONSerialization dataWithJSONObject:@{@"ok":@(!error), @"error":error ?: @"", @"profiles":self.evidence ?: @{}, @"profileLoadMilliseconds":self.profileLoadMilliseconds ?: @{}} options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:report atomically:YES];
  }
  [AircEngine.sharedEngine quit];
}
- (void)window:(AircWindow*)window didInsertTab:(AircTab*)tab opener:(AircTab*)opener disposition:(NSString*)disposition {
  self.insertionCallbacks++;
}
- (BOOL)engine:(AircEngine*)engine routeLink:(NSDictionary*)request opener:(AircTab*)opener {
  if (!self.featureRoutes) return NO;
  NSMutableDictionary* record = [request mutableCopy];
  record[@"handled"] = @YES;
  [self.featureRoutes addObject:record];
  // A profile-routing decision starts a fresh navigation. It never migrates a popup's profile.
  dispatch_async(dispatch_get_main_queue(), ^{
    AircTab* tab = [self.browserWindow openTab:request[@"url"] profile:self.tabs[1].profile foreground:NO];
    [self.tabs addObject:tab];
    record[@"destinationProfileCorrect"] = @(tab.profile == self.tabs[1].profile);
  });
  return YES;
}
- (void)engineWillShutDown {}
- (void)engineQuitCancelled {}
- (AircWindow*)engineWindowForNewBrowserOfProfile:(AircProfile*)profile type:(NSString*)type { return self.browserWindow; }
- (BOOL)windowShouldClose:(AircWindow*)window { [AircEngine.sharedEngine quit]; return NO; }
- (BOOL)engineIsReservedKeyEvent:(NSEvent*)event { return NO; }
- (BOOL)engineIsReservedKey:(NSString*)key unshiftedKey:(NSString*)unshifted modifiers:(NSEventModifierFlags)modifiers { return NO; }
- (void)engine:(AircEngine*)engine permissionRequest:(NSDictionary*)request tab:(AircTab*)tab {
  // Keep Chromium's capture indicator alive: fake-UI bypasses it and therefore
  // makes the call ineligible for auto PiP. Only this scratch fake-device probe
  // grants media; the ordinary host still denies prompts below.
  if (([Flag(@"--airc-native-case") isEqual:@"pip"] || [Flag(@"--airc-smoke") isEqual:@"pass12"] || [Flag(@"--airc-smoke") isEqual:@"pass13"]) &&
      [NSProcessInfo.processInfo.arguments containsObject:@"--use-fake-device-for-media-stream"] &&
      [request[@"permissions"] count] &&
      [[NSSet setWithArray:request[@"permissions"]] isSubsetOfSet:[NSSet setWithArray:@[@"camera", @"microphone"]]]) {
    self.evidence[@"fakeCapturePermission"] = request;
    [AircEngine resolvePermission:request[@"id"] result:@"accept" remember:NO]; return;
  }
  if ([Flag(@"--airc-smoke") isEqual:@"surfaces"] || [Flag(@"--airc-native-case") isEqual:@"permissions"]) {
    NSRect rect = self.browserWindow.uiAnchorRectInScreen;
    NSMutableDictionary* evidence = [request mutableCopy];
    evidence[@"anchor"] = NSStringFromRect(rect);
    evidence[@"correctProfile"] = @(tab.profile == self.tabs[0].profile);
    for (NSString* kind in request[@"permissions"]) self.evidence[kind] = evidence;
  }
  [AircEngine resolvePermission:request[@"id"] result:@"deny" remember:YES];
}
- (void)engine:(AircEngine*)engine permissionRequestDismissed:(NSString*)requestId {}
- (void)engine:(AircEngine*)engine extensionSidePanel:(NSDictionary*)panel tab:(AircTab*)tab {}
- (BOOL)engine:(AircEngine*)engine extensionActionPopup:(NSDictionary*)popup tab:(AircTab*)tab { return NO; }
- (BOOL)engine:(AircEngine*)engine extensionActionShortcut:(NSDictionary*)shortcut tab:(AircTab*)tab { return NO; }
- (void)engine:(AircEngine*)engine extensionInstallPrompt:(NSDictionary*)prompt profile:(AircProfile*)profile tab:(AircTab*)tab {
  BOOL expected = [Flag(@"--airc-smoke") isEqualToString:@"extension"] &&
      [prompt[@"id"] isEqualToString:@"ddkjiahejlhfcafbddmgiahcphecmpfh"] && profile == self.tabs[0].profile;
  self.evidence[@"installPrompt"] = prompt;
  [AircEngine resolveExtensionInstallPrompt:prompt[@"requestId"] accepted:expected];
}
- (void)engine:(AircEngine*)engine extensionInstallFailed:(NSString*)message tab:(AircTab*)tab { self.evidence[@"installError"] = message; }
- (void)engine:(AircEngine*)engine deviceChooser:(NSDictionary*)chooser tab:(AircTab*)tab {}
- (void)engine:(AircEngine*)engine castDialog:(NSDictionary*)dialog tab:(AircTab*)tab {}
- (void)engine:(AircEngine*)engine castRoutes:(NSArray*)routes profile:(AircProfile*)profile {}
@end
int main(int argc, const char** argv) {
  @autoreleasepool {
    if (!Flag(@"--user-data-dir")) { fprintf(stderr, "Explicit --user-data-dir required\n"); return 64; }
    Host* host = [Host new];
    return [AircEngine runWithArgc:argc argv:argv delegate:host];
  }
}

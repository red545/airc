// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#import <AppKit/AppKit.h>
#import "Airc.h"
static NSString* Arg(NSString* name) {
  for (NSString* arg in NSProcessInfo.processInfo.arguments) {
    NSString* prefix = [name stringByAppendingString:@"="];
    if ([arg hasPrefix:prefix]) return [arg substringFromIndex:prefix.length];
  }
  return nil;
}
@interface DRMHost : NSObject <AircEngineDelegate>
@property NSWindow* window;
@property AircWindow* browser;
@property AircTab* tab;
@property NSTimer* timer;
@property NSMutableDictionary* results;
@property NSInteger ticks;
@property BOOL started;
@property BOOL finished;
@end
@implementation DRMHost
- (void)finish:(NSString*)reason {
  if (self.finished) return;
  self.finished=YES; [self.timer invalidate];
  self.results[@"finish"]=reason;
  self.results[@"state"]=AircEngine.sharedEngine.protectedContentState;
  NSData* data=[NSJSONSerialization dataWithJSONObject:self.results options:NSJSONWritingPrettyPrinted error:nil];
  [data writeToFile:Arg(@"--drm-result") atomically:YES];
  [AircEngine.sharedEngine quit];
}
- (void)engineDidStart {
  self.results=[NSMutableDictionary dictionary];
  [[NSString stringWithFormat:@"%d",getpid()] writeToFile:Arg(@"--drm-pid") atomically:YES encoding:NSUTF8StringEncoding error:nil];
  AircEngine* engine=AircEngine.sharedEngine;
  self.results[@"initialState"]=engine.protectedContentState;
  if (Arg(@"--drm-enabled")) engine.protectedContentEnabled=[Arg(@"--drm-enabled") isEqual:@"on"];
  self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,720,500)
    styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  self.window.releasedWhenClosed=NO;
  self.browser=[[AircWindow alloc] initWithWindow:self.window hostView:self.window.contentView];
  [engine loadProfile:(Arg(@"--drm-profile") ?: @"DRM Test") completion:^(AircProfile* profile) {
    self.tab=[self.browser openTab:Arg(@"--drm-url") profile:profile foreground:YES];
    [self.browser activateTab:self.tab];
    [self.tab attachToView:self.window.contentView];
    // Keep behind the owner's windows. No focus, device or screenshot requests.
    [self.window orderBack:nil];
    [self.tab setPageVisible:YES];
    self.timer=[NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer* t){[self tick];}];
  }];
}
- (void)tick {
  if (++self.ticks>210) { [self finish:@"deadline"]; return; }
  NSDictionary* state=AircEngine.sharedEngine.protectedContentState;
  NSData* status=[NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:nil];
  [status writeToFile:[Arg(@"--drm-result") stringByAppendingString:@".state.json"] atomically:YES];
  if (self.started) {
    [self.tab evaluate:@"window.evidence || {}" completion:^(NSString* json) {
      [json writeToFile:[Arg(@"--drm-result") stringByAppendingString:@".progress.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }];
    return;
  }
  BOOL off=!AircEngine.sharedEngine.protectedContentEnabled;
  NSString* version=state[@"cdmVersion"];
  if (!off && (!version.length || [version isEqual:@"0.0.0.0"])) return;
  self.started=YES;
  self.results[@"window"]=@{@"visible":@(self.window.visible),@"hiddenApp":@(NSApp.hidden),@"pageVisible":@(self.tab.pageVisible),@"hiddenView":@(self.tab.view.hidden)};
  [self.tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"probe()",@"awaitPromise":@YES,@"returnByValue":@YES}
    timeout:25 completion:^(NSDictionary* response, NSString* error) {
    self.results[@"eme"]=response ?: @{}; if(error) self.results[@"emeError"]=error;
    if(off) {
      // Stay alive past the normal one-minute first update timer so the NetLog
      // tests exercise disabled networking, not just an early browser exit.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,70*NSEC_PER_SEC),dispatch_get_main_queue(),^{[self finish:@"off-probe"];});
      return;
    }
    [self.tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"playDemo()",@"awaitPromise":@YES,@"returnByValue":@YES,@"userGesture":@YES}
      timeout:110 completion:^(NSDictionary* play, NSString* failure) {
      self.results[@"demo"]=play ?: @{}; if(failure) self.results[@"demoError"]=failure;
      [self finish:@"probes-complete"];
    }];
  }];
}
- (void)engineWillShutDown {}
- (void)engineQuitCancelled { [self finish:@"quit-cancelled"]; }
- (AircWindow*)engineWindowForNewBrowserOfProfile:(AircProfile*)profile type:(NSString*)type { return nil; }
- (void)engine:(AircEngine*)engine permissionRequest:(NSDictionary*)request tab:(AircTab*)tab {
  [AircEngine resolvePermission:request[@"id"] result:@"deny" remember:NO];
}
- (void)engine:(AircEngine*)engine permissionRequestDismissed:(NSString*)requestId {}
- (void)engine:(AircEngine*)engine extensionSidePanel:(NSDictionary*)panel tab:(AircTab*)tab {}
- (BOOL)engine:(AircEngine*)engine extensionActionPopup:(NSDictionary*)popup tab:(AircTab*)tab { return NO; }
- (BOOL)engine:(AircEngine*)engine extensionActionShortcut:(NSDictionary*)shortcut tab:(AircTab*)tab { return NO; }
- (BOOL)engineIsReservedKeyEvent:(NSEvent*)event { return NO; }
- (BOOL)engineIsReservedKey:(NSString*)key unshiftedKey:(NSString*)unshiftedKey modifiers:(NSEventModifierFlags)modifiers { return NO; }
- (void)engine:(AircEngine*)engine extensionInstallPrompt:(NSDictionary*)prompt profile:(AircProfile*)profile tab:(AircTab*)tab {
  [AircEngine resolveExtensionInstallPrompt:prompt[@"id"] accepted:NO];
}
- (void)engine:(AircEngine*)engine extensionInstallFailed:(NSString*)message tab:(AircTab*)tab {}
- (void)engine:(AircEngine*)engine deviceChooser:(NSDictionary*)chooser tab:(AircTab*)tab {
  [AircEngine cancelDeviceChooser:[chooser[@"id"] intValue]];
}
- (void)engine:(AircEngine*)engine castDialog:(NSDictionary*)dialog tab:(AircTab*)tab {
  [AircEngine closeCastDialog:[dialog[@"id"] intValue]];
}
- (void)engine:(AircEngine*)engine castRoutes:(NSArray*)routes profile:(AircProfile*)profile {}
@end
int main(int argc, const char** argv) {
  @autoreleasepool {
    DRMHost* host=[DRMHost new];
    return [AircEngine runWithArgc:argc argv:argv delegate:host];
  }
}

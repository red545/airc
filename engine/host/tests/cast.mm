// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#import <AppKit/AppKit.h>
#import "Airc.h"
static NSString* Flag(NSString* key) {
  NSString* prefix = [key stringByAppendingString:@"="];
  for (NSString* a in NSProcessInfo.processInfo.arguments)
    if ([a hasPrefix:prefix]) return [a substringFromIndex:prefix.length];
  return nil;
}
static void Later(double seconds, dispatch_block_t block) {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC), dispatch_get_main_queue(), block);
}
@interface Host : NSObject <AircEngineDelegate>
@property AircWindow* window;
@property AircTab* tab;
@property NSMutableDictionary* results;
@property BOOL finished;
@property int stage;
@property int dialog;
@property NSString* route;
@end
@implementation Host
- (void)engineWillShutDown {}
- (void)engineQuitCancelled { [self finish:@"quit cancelled"]; }
- (AircWindow*)engineWindowForNewBrowserOfProfile:(AircProfile*)profile type:(NSString*)type { return self.window; }
- (BOOL)engineIsReservedKeyEvent:(NSEvent*)event { return NO; }
- (BOOL)engineIsReservedKey:(NSString*)key unshiftedKey:(NSString*)unshiftedKey modifiers:(NSEventModifierFlags)modifiers { return NO; }
- (void)engine:(AircEngine*)engine permissionRequest:(NSDictionary*)request tab:(AircTab*)tab {
  [AircEngine resolvePermission:request[@"id"] result:@"deny" remember:NO];
}
- (void)engine:(AircEngine*)engine permissionRequestDismissed:(NSString*)requestId {}
- (void)engine:(AircEngine*)engine extensionSidePanel:(NSDictionary*)panel tab:(AircTab*)tab {}
- (BOOL)engine:(AircEngine*)engine extensionActionPopup:(NSDictionary*)popup tab:(AircTab*)tab { return NO; }
- (BOOL)engine:(AircEngine*)engine extensionActionShortcut:(NSDictionary*)shortcut tab:(AircTab*)tab { return NO; }
- (void)engine:(AircEngine*)engine extensionInstallPrompt:(NSDictionary*)prompt profile:(AircProfile*)profile tab:(AircTab*)tab {}
- (void)engine:(AircEngine*)engine extensionInstallFailed:(NSString*)message tab:(AircTab*)tab {}
- (void)engine:(AircEngine*)engine deviceChooser:(NSDictionary*)chooser tab:(AircTab*)tab {}
- (void)engine:(AircEngine*)engine castDialog:(NSDictionary*)dialog tab:(AircTab*)tab {
  self.dialog = [dialog[@"id"] intValue];
  if (![dialog[@"open"] boolValue]) return;
  self.results[@"hostCallback"] = @YES;
  if ([Flag(@"--case") isEqual:@"empty"]) {
    self.results[@"noDevices"] = @([dialog[@"sinks"] count] == 0);
    Later(.2, ^{ [AircEngine closeCastDialog:self.dialog]; [self finish:nil]; });
    return;
  }
  for (NSDictionary* sink in dialog[@"sinks"]) {
    if (![sink[@"id"] isEqual:@"ac-test-sink"]) continue;
    if (self.stage == 0 && ([sink[@"modes"] intValue] & 2)) {
      self.stage = 1;
      Later(.1, ^{ [AircEngine startCasting:self.dialog sink:@"ac-test-sink" mode:2]; });
    } else if (self.stage == 1 && [sink[@"state"] isEqual:@"connected"]) {
      self.stage = 2; self.route = sink[@"routeId"];
      self.results[@"connected"] = @YES;
      Later(.2, ^{ [AircEngine closeCastDialog:self.dialog];
        Later(.2, ^{ [AircEngine terminateCastRoute:self.route]; }); });
    }
  }
}
- (void)engine:(AircEngine*)engine castRoutes:(NSArray*)routes profile:(AircProfile*)profile {
  self.results[@"profileRoutesCallback"] = @YES;
  if (self.stage == 2 && routes.count == 0) {
    self.stage = 3; self.results[@"ended"] = @YES; Later(.1, ^{ [self finish:nil]; });
  }
}
- (void)finish:(NSString*)error {
  if (self.finished) return;
  self.finished = YES;
  self.results[@"error"] = error ?: NSNull.null;
  [[NSJSONSerialization dataWithJSONObject:self.results options:NSJSONWritingPrettyPrinted error:nil]
      writeToFile:[Flag(@"--output") stringByAppendingPathComponent:@"results.json"] atomically:YES];
  [AircEngine.sharedEngine quit];
}
- (void)engineDidStart {
  self.results = [NSMutableDictionary dictionary];
  Later(75, ^{ [self finish:@"test deadline"]; });
  NSWindow* native = [[NSWindow alloc] initWithContentRect:NSMakeRect(100,100,800,500)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  native.releasedWhenClosed = NO;
  self.window = [[AircWindow alloc] initWithWindow:native hostView:native.contentView];
  [AircEngine.sharedEngine loadProfile:@"API Fixture" completion:^(AircProfile* profile) {
    self.tab = [self.window openTab:@"data:text/html,<title>Cast fixture</title>" profile:profile foreground:YES];
    [self.tab attachToView:self.window.hostView];
    [self.window showInactive];
    [profile watchCastRoutes];
    Later(1, ^{ if (![self.tab showCastDialog]) [self finish:@"router unavailable"]; });
  }];
}
@end
int main(int argc, const char** argv) {
  @autoreleasepool { return [AircEngine runWithArgc:argc argv:argv delegate:[Host new]]; }
}

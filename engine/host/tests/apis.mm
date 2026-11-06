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
- (void)engine:(AircEngine*)engine castDialog:(NSDictionary*)dialog tab:(AircTab*)tab {}
- (void)engine:(AircEngine*)engine castRoutes:(NSArray*)routes profile:(AircProfile*)profile {}
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
    self.tab = [self.window openTab:Flag(@"--fixture") profile:profile foreground:YES];
    [self.tab attachToView:self.window.hostView];
    [self.window showInactive];
    [self ready:0 then:^{ [self save:0]; }];
  }];
}
- (void)ready:(int)attempt then:(dispatch_block_t)done {
  if (attempt > 100) { [self finish:@"load deadline"]; return; }
  if (self.tab.loading || ![self.tab.title isEqual:@"Airc API fixture"]) {
    Later(.1, ^{ [self ready:attempt+1 then:done]; }); return;
  }
  Later(.3, done);
}
- (void)save:(int)format {
  if (format == 3) { [self snapshot]; return; }
  NSString* name = @[@"html.html", @"complete.html", @"single.mhtml"][format];
  NSString* path = [Flag(@"--output") stringByAppendingPathComponent:name];
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  [self.tab savePageTo:path format:(AircSavePageFormat)format completion:^(NSString* error) {
    self.results[[name stringByAppendingString:@"Ms"]] = @((CFAbsoluteTimeGetCurrent()-start)*1000);
    if (error || !NSThread.isMainThread) { [self finish:error ?: @"save off main"]; return; }
    NSNumber* bytes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileSize];
    self.results[[name stringByAppendingString:@"Bytes"]] = bytes ?: @0;
    if (!bytes.unsignedLongLongValue) {
      [self finish:@"empty save"]; return;
    }
    if (format == 1 && ![NSFileManager.defaultManager fileExistsAtPath:[Flag(@"--output") stringByAppendingPathComponent:@"complete_files/art.svg"]]) {
      [self finish:@"missing complete resource"]; return;
    }
    [self.tab loadURL:[NSURL fileURLWithPath:path].absoluteString userInitiated:NO];
    [self ready:0 then:^{
      dispatch_block_t reopened = ^{
        self.results[[name stringByAppendingString:@"Reopened"]] = @YES;
        [self.tab loadURL:Flag(@"--fixture") userInitiated:NO];
        [self ready:0 then:^{ [self save:format+1]; }];
      };
      if (format == 2) {
        // MHTML disables main-world script execution. Verify its rendered
        // fixture instead of treating the evaluation API's nil as bad content.
        [self.tab snapshotWithMaxSize:CGSizeMake(640,400) completion:^(NSImage* image) {
          NSBitmapImageRep* rep = image ? [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation] : nil;
          if (!rep || rep.pixelsWide < 100 || rep.pixelsHigh < 100) {
            [self finish:@"MHTML reopen missing surface"]; return;
          }
          NSColor* left = [[rep colorAtX:20 y:rep.pixelsHigh/2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
          NSColor* right = [[rep colorAtX:rep.pixelsWide-20 y:rep.pixelsHigh/2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
          if (left.redComponent < .8 || right.blueComponent < .8 || right.redComponent > .2) {
            [self finish:@"MHTML reopen pixel mismatch"]; return;
          }
          self.results[@"mhtmlRenderedFixture"] = @YES;
          reopened();
        }];
      } else {
        [self.tab evaluate:@"post('result', JSON.stringify(document.body.innerText.includes('Airc API fixture')))" completion:^(NSString* json) {
          if (![json isEqual:@"true"]) { [self finish:@"reopen content mismatch"]; return; }
          reopened();
        }];
      }
    }];
  }];
  [self.tab savePageTo:[path stringByAppendingString:@".busy"] format:(AircSavePageFormat)format completion:^(NSString* error) {
    if (![error isEqual:@"busy"]) [self finish:@"overlapping save was not busy"];
    self.results[@"busy"] = @YES;
  }];
}
- (void)snapshot {
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  [self.tab snapshotWithMaxSize:CGSizeMake(640,400) completion:^(NSImage* image) {
    self.results[@"snapshotMs"] = @((CFAbsoluteTimeGetCurrent()-start)*1000);
    if (!image || !NSThread.isMainThread) { [self finish:@"missing snapshot or off main"]; return; }
    NSBitmapImageRep* rep = [NSBitmapImageRep imageRepWithData:image.TIFFRepresentation];
    self.results[@"snapshotPixels"] = @[@(rep.pixelsWide), @(rep.pixelsHigh)];
    if (rep.pixelsWide > 640 || rep.pixelsHigh > 400 || rep.pixelsWide < 100 || rep.pixelsHigh < 100) {
      [self finish:@"snapshot size"]; return;
    }
    NSColor* left = [[rep colorAtX:20 y:rep.pixelsHigh/2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor* right = [[rep colorAtX:rep.pixelsWide-20 y:rep.pixelsHigh/2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (fabs(left.redComponent-right.redComponent) < .4) { [self finish:@"blank snapshot"]; return; }
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
      writeToFile:[Flag(@"--output") stringByAppendingPathComponent:@"snapshot.png"] atomically:YES];
    [@"not a directory" writeToFile:[Flag(@"--output") stringByAppendingPathComponent:@"blocked"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self.tab savePageTo:[Flag(@"--output") stringByAppendingPathComponent:@"blocked/fail.html"]
      format:AircSavePageFormatHTML completion:^(NSString* error) {
        if (!error) { [self finish:@"write failure reported success"]; return; }
        self.results[@"writeError"] = error;
        [self hidden];
      }];
  }];
}
- (void)hidden {
  [self.tab detachFromHost];
  [self.window deactivateAll];
  Later(.3, ^{
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [self.tab snapshotWithMaxSize:CGSizeMake(640,400) completion:^(NSImage* image) {
      self.results[@"hiddenSnapshot"] = @(image != nil);
      self.results[@"hiddenSnapshotMs"] = @((CFAbsoluteTimeGetCurrent()-start)*1000);
      [self discard:0];
    }];
  });
}
- (void)discard:(int)attempt {
  if (![self.tab discard]) {
    if (attempt > 20) { [self finish:@"discard refused"]; return; }
    Later(.25, ^{ [self discard:attempt+1]; }); return;
  }
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  [self.tab snapshotWithMaxSize:CGSizeMake(640,400) completion:^(NSImage* image) {
    self.results[@"discardSnapshotMs"] = @((CFAbsoluteTimeGetCurrent()-start)*1000);
    if (image) { [self finish:@"discarded snapshot nonnil"]; return; }
    self.results[@"discardedNil"] = @YES;
    [self.tab loadURL:@"chrome://version" userInitiated:NO];
    Later(1, ^{
      if (self.tab.canSavePage) { [self finish:@"chrome page savable"]; return; }
      [self.tab savePageTo:[Flag(@"--output") stringByAppendingPathComponent:@"chrome.html"]
          format:AircSavePageFormatHTML completion:^(NSString* error) {
        self.results[@"unsupported"] = error ?: NSNull.null;
        if (![error isEqual:@"notSavable"]) [self finish:@"unsupported did not fail"];
        else [self cancellation];
      }];
    });
  }];
}
- (void)cancellation {
  [self.tab loadURL:Flag(@"--fixture") userInitiated:NO];
  [self ready:0 then:^{
    NSString* path = [Flag(@"--output") stringByAppendingPathComponent:@"cancel.html"];
    __weak Host* weak = self;
    [self.tab.profile observeDownloads:^(NSDictionary* row) {
      if ([row[@"path"] isEqual:path] && [row[@"state"] intValue] == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [weak.tab.profile performDownloadAction:@"cancel" identifier:row[@"id"]];
        });
      }
    }];
    [self.tab savePageTo:path format:AircSavePageFormatHTML completion:^(NSString* error) {
      [self.tab.profile observeDownloads:nil];
      self.results[@"cancelError"] = error ?: NSNull.null;
      [self finish:[error isEqual:@"cancelled"] ? nil : @"download cancel completion"];
    }];
  }];
}

@end
int main(int argc, const char** argv) {
  @autoreleasepool { return [AircEngine runWithArgc:argc argv:argv delegate:[Host new]]; }
}

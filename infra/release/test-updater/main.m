// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#import <Cocoa/Cocoa.h>
#import <Sparkle/Sparkle.h>
static void record(NSString *text) {
 NSString *path=[[NSBundle mainBundle] objectForInfoDictionaryKey:@"ProofLog"];
 NSFileHandle *f=[NSFileHandle fileHandleForWritingAtPath:path];
 if (!f) { [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; f=[NSFileHandle fileHandleForWritingAtPath:path]; }
 [f seekToEndOfFile]; [f writeData:[[text stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]]; [f closeFile];
}
@interface Driver : NSObject <NSApplicationDelegate,SPUUserDriver,SPUUpdaterDelegate>
@property SPUUpdater *updater;
@end
@implementation Driver
- (void)applicationDidFinishLaunching:(NSNotification *)n {
 NSString *v=[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
 record([@"LAUNCHED " stringByAppendingString:v]);
 if ([v isEqual:@"0.0.2"]) { record(@"PASS installed and relaunched 0.0.2"); [NSApp terminate:nil]; return; }
 self.updater=[[SPUUpdater alloc] initWithHostBundle:NSBundle.mainBundle applicationBundle:NSBundle.mainBundle userDriver:self delegate:self];
 NSError *e=nil; if (![self.updater startUpdater:&e]) { record(e.description); exit(1); }
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),dispatch_get_main_queue(),^{ [self.updater checkForUpdates]; });
 dispatch_after(dispatch_time(DISPATCH_TIME_NOW,120*NSEC_PER_SEC),dispatch_get_main_queue(),^{record(@"FAIL timeout");exit(1);});
}
- (NSSet<NSString *> *)allowedChannelsForUpdater:(SPUUpdater *)updater { return [NSSet setWithObject:([[NSBundle mainBundle] objectForInfoDictionaryKey:@"ProofChannel"] ?: @"stable")]; }
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply { reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:YES sendSystemProfile:NO]); }
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation { record(@"CHECK"); }
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply { record([@"FOUND " stringByAppendingString:item.displayVersionString]); reply(SPUUserUpdateChoiceInstall); }
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error { record(error.description); }
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))ack { record(error.description); ack(); exit(1); }
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))ack { record(error.description); ack(); exit(1); }
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancel { record(@"DOWNLOAD"); }
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate { record(@"EXTRACT"); }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply { record(@"VERIFIED; INSTALL AND RELAUNCH"); reply(SPUUserUpdateChoiceInstall); }
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry { record(@"INSTALLING"); }
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))ack { record(@"INSTALLED"); ack(); }
- (void)dismissUpdateInstallation {}
@end
int main(void) { @autoreleasepool { NSApplication *app=NSApplication.sharedApplication; [app setActivationPolicy:NSApplicationActivationPolicyProhibited]; Driver *d=[Driver new]; app.delegate=d; [app run]; } return 0; }

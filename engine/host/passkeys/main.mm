// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#import <AppKit/AppKit.h>
#import "Airc.h"
static NSString* Flag(NSString* key) {
  NSString* prefix = [key stringByAppendingString:@"="];
  for (NSString* arg in NSProcessInfo.processInfo.arguments)
    if ([arg hasPrefix:prefix]) return [arg substringFromIndex:prefix.length];
  return nil;
}
@interface PasskeyHost : NSObject <AircEngineDelegate>
@property AircWindow* window;
@property AircTab* tab;
@property NSMutableArray* results;
@property BOOL finished;
@end
@implementation PasskeyHost
- (void)finish:(NSString*)error {
  if (self.finished) return;
  self.finished = YES;
  NSDictionary* report = @{@"passed":@(!error), @"error":error ?: @"", @"checks":self.results ?: @[]};
  [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
      writeToFile:Flag(@"--report") atomically:YES];
  [AircEngine.sharedEngine quit];
}
- (void)call:(NSString*)method params:(NSDictionary*)params done:(void (^)(NSDictionary*))done {
  [self.tab devToolsCall:method params:params timeout:15 completion:^(NSDictionary* r, NSString* e) {
    if (e || r[@"exceptionDetails"]) { [self finish:e ?: r.description]; return; }
    done(r);
  }];
}
- (void)check {
  [self call:@"Runtime.evaluate" params:@{@"expression":@"({readyState:document.readyState,focused:document.hasFocus(),visibility:document.visibilityState})",@"returnByValue":@YES} done:^(NSDictionary* r) {
    if (![r[@"result"][@"value"][@"readyState"] isEqual:@"complete"]) {
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{[self check];}); return;
    }
    NSWindow* w = self.window.window;
    BOOL visible = (w.occlusionState & NSWindowOcclusionStateVisible) != 0;
    [self.results addObject:@{@"page":r[@"result"][@"value"] ?: @{},
        @"windowVisible":@(w.visible), @"onActiveSpace":@(w.onActiveSpace),
        @"unoccluded":@(visible), @"windowKey":@(w.keyWindow),
        @"windowNumber":@(w.windowNumber), @"pid":@(getpid()),
        @"hostPageVisible":@(self.tab.pageVisible)}];
    if (!w.visible || !w.onActiveSpace || !visible) {
      [self finish:@"FAIL-ENV: fixture window is hidden, off Space or occluded; retry with the owner's idle display"];
      return;
    }
    // Retain the CDP session so the virtual authenticator survives calls.
    [self.tab devToolsCall:@"Runtime.evaluate" params:@{@"expression":@"new Promise(r=>window.releaseCDP=r)",@"awaitPromise":@YES} timeout:45 completion:^(NSDictionary* r, NSString* e) {}];
    // CDP focus emulation is confined to this virtual fixture. Never activate
    // the app or move the owner away from their current window/Space.
    [self call:@"Emulation.setFocusEmulationEnabled" params:@{@"enabled":@YES} done:^(NSDictionary* r) {
      [self call:@"WebAuthn.enable" params:@{@"enableUI":@NO} done:^(NSDictionary* r) {
        [self call:@"WebAuthn.addVirtualAuthenticator" params:@{@"options":@{@"protocol":@"ctap2",@"transport":@"internal",@"hasResidentKey":@YES,@"hasUserVerification":@YES,@"isUserVerified":@YES,@"automaticPresenceSimulation":@YES}} done:^(NSDictionary* r) {
          NSString* aid = r[@"authenticatorId"];
          NSString* script = @"(async()=>{const c=await navigator.credentials.create({publicKey:{challenge:crypto.getRandomValues(new Uint8Array(32)),rp:{name:'Synthetic Airc'},user:{id:new Uint8Array([1]),name:'fixture',displayName:'Fixture'},pubKeyCredParams:[{type:'public-key',alg:-7}],authenticatorSelection:{residentKey:'required',userVerification:'required',authenticatorAttachment:'platform'}}});const a=await navigator.credentials.get({publicKey:{challenge:crypto.getRandomValues(new Uint8Array(32)),userVerification:'required'}});return {created:c.type,asserted:a.type,sameId:c.id===a.id,discoverable:true,conditionalAvailable:await PublicKeyCredential.isConditionalMediationAvailable()}})()";
          [self call:@"Runtime.evaluate" params:@{@"expression":script,@"userGesture":@YES,@"awaitPromise":@YES,@"returnByValue":@YES} done:^(NSDictionary* r) {
            NSDictionary* value=r[@"result"][@"value"];
            [self.results addObject:value ?: @{}];
            if (![value[@"conditionalAvailable"] boolValue]) { [self finish:@"conditional mediation unavailable"]; return; }
            if (![value[@"sameId"] boolValue]) { [self finish:@"discoverable assertion did not match creation"]; return; }
            [self call:@"WebAuthn.getCredentials" params:@{@"authenticatorId":aid} done:^(NSDictionary* r) {
              NSArray* credentials=r[@"credentials"];
              if (credentials.count != 1 || ![credentials[0][@"isResidentCredential"] boolValue]) {
                [self finish:@"resident credential not enumerated"]; return;
              }
              [self call:@"WebAuthn.clearCredentials" params:@{@"authenticatorId":aid} done:^(NSDictionary* r) {
                [self call:@"WebAuthn.getCredentials" params:@{@"authenticatorId":aid} done:^(NSDictionary* r) {
                  BOOL gone=[r[@"credentials"] count]==0;
                  [self.results addObject:@{@"virtualCredentialDeleted":@(gone)}];
                  [self call:@"WebAuthn.removeVirtualAuthenticator" params:@{@"authenticatorId":aid} done:^(NSDictionary* r) {
                    if (!gone) { [self finish:@"virtual credential remained"]; return; }
                    AircProfile* profile=self.tab.profile;
                    [self.tab close];
                    self.tab=nil;
                    [self.window deactivateAll];
                    [AircEngine.sharedEngine deleteProfile:profile completion:^(BOOL deleted) {
                      [self.results addObject:@{@"scratchProfileDeletionAccepted":@(deleted)}];
                      [self finish:deleted ? nil : @"scratch profile deletion failed"];
                    }];
                  }];
                }];
              }];
            }];
          }];
        }];
      }];
    }];
  }];
}
- (void)engineDidStart {
  self.results=[NSMutableArray array];
  [[NSString stringWithFormat:@"%d",getpid()] writeToFile:Flag(@"--pid") atomically:YES encoding:NSUTF8StringEncoding error:nil];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_SEC),dispatch_get_main_queue(),^{[self finish:@"fixture timeout"];});
  NSWindow* w=[[NSWindow alloc] initWithContentRect:NSMakeRect(120,120,760,540)
      styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
  w.releasedWhenClosed=NO;
  self.window=[[AircWindow alloc] initWithWindow:w hostView:w.contentView];
  [AircEngine.sharedEngine loadProfile:@"PasskeyFixture" completion:^(AircProfile* p) {
    self.tab=[self.window openTab:Flag(@"--url") profile:p foreground:YES];
    [self.window activateTab:self.tab];
    [self.tab attachToView:w.contentView];
    [self.window showInactive];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{[self check];});
  }];
}
@end
int main(int argc,const char** argv) {
  @autoreleasepool {
    if (!Flag(@"--user-data-dir") || !Flag(@"--report") || !Flag(@"--pid")) return 64;
    PasskeyHost* host=[PasskeyHost new];
    return [AircEngine runWithArgc:argc argv:argv delegate:host];
  }
}

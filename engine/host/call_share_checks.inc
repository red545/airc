// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Host-level fail-closed and per-profile observer checks; no device API calls.
- (void)callShareCheck {
  AircTab* call = self.tabs[0];
  AircTab* other = self.tabs[1];
  __block NSUInteger firstCallbacks = 0, otherCallbacks = 0;
  [call.profile observeCallShares:^(NSArray* rows) { ++firstCallbacks; }];
  [other.profile observeCallShares:^(NSArray* rows) { ++otherCallbacks; }];
  BOOL idle = call.profile.callShares.count == 0 && other.profile.callShares.count == 0;
  BOOL rejected = ![other canShareThisTabInsteadFor:call] &&
                  ![other shareThisTabInsteadFor:call] &&
                  ![call canShareThisTabInsteadFor:call] && ![call stopCapture];
  self.evidence[@"p16bIdleCaptureSnapshots"] = @(idle);
  self.evidence[@"p16bCrossProfileAndIdleRejected"] = @(rejected);
  self.evidence[@"p16bProfileObservers"] = @(firstCallbacks == 1 && otherCallbacks == 1);
  [call.profile observeCallShares:nil];
  [other.profile observeCallShares:nil];
  [self finish:idle && rejected && firstCallbacks == 1 && otherCallbacks == 1 ? nil : @"call sharing host contract failed"];
}

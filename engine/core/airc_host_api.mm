// Copyright 2026 The Airc Authors
// SPDX-License-Identifier: Apache-2.0
#import "airc/core/public/Airc.h"
#import <objc/runtime.h>
#import "airc/core/airc_internal.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "chrome/browser/profiles/profile_attributes_entry.h"
#include "chrome/browser/profiles/profile_attributes_storage.h"
#include "extensions/browser/extension_registry.h"
#include "airc/core/airc_browser.h"
#include "airc/core/airc_host_visibility.h"
#include "content/public/browser/web_contents.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest.h"

@implementation AircEngine (HostAPI)
- (NSArray<NSString*>*)profileDirectoryNames {
  NSMutableArray* names = [NSMutableArray array];
  for (auto* entry : g_browser_process->profile_manager()
                         ->GetProfileAttributesStorage().GetAllProfilesAttributes()) {
    NSString* name = base::SysUTF8ToNSString(entry->GetPath().BaseName().value());
    if (![name isEqualToString:@"Airc Internal"]) [names addObject:name];
  }
  return names;
}
- (void)createProfileWithCompletion:(void (^)(AircProfile*))completion {
  [self loadProfile:[@"Profile " stringByAppendingString:NSUUID.UUID.UUIDString]
         completion:completion];
}
- (void)loadInternalProfileWithCompletion:(void (^)(AircProfile*))completion {
  [self loadProfile:@"Airc Internal" completion:completion];
}
@end

@implementation AircProfile (HostAPI)
- (NSArray<NSDictionary<NSString*,id>*>*)extensions {
  NSMutableArray* result = [NSMutableArray array];
  if (!self.chromeProfile || self.destroyed) return result;
  auto* registry = extensions::ExtensionRegistry::Get(self.chromeProfile);
  for (const auto& extension : registry->GenerateInstalledExtensionsSet()) {
    if (extensions::Manifest::IsComponentLocation(extension->location())) continue;
    [result addObject:@{@"id": base::SysUTF8ToNSString(extension->id()),
                        @"name": base::SysUTF8ToNSString(extension->name()),
                        @"version": base::SysUTF8ToNSString(extension->version().GetString()),
                        @"enabled": @(registry->enabled_extensions().Contains(extension->id()))}];
  }
  return result;
}
@end

@implementation AircTab (Hosting)
- (BOOL)pageVisible { return airc::ShownByHost(self.contents).value_or(false); }
- (void)attachToView:(NSView*)host {
  NSParameterAssert(NSThread.isMainThread);
  if (self.view.superview == host) { [self setPageVisible:YES]; return; }
  [self.view removeFromSuperview];
  self.view.frame = host.bounds;
  self.view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.view.hidden = NO;
  [host addSubview:self.view];
  [self noteShownByHost:host.window != nil];
  [self noteShownInWindow];
}
// MEM-6: a page shown in an ordered-out window is hidden like the window's others (WindowHost).
- (void)noteShownInWindow {
  if (!self.contents || self.view.hidden || !self.view.window) return;
  if (airc::WindowHost* host = airc::WindowHost::ForNSWindow(self.view.window)) {
    host->PageShownByHost(self.contents);
  }
}
- (void)setPageVisible:(BOOL)visible {
  NSParameterAssert(NSThread.isMainThread);
  NSView* view = self.view;
  if (!visible && [view.window.firstResponder isKindOfClass:NSView.class] &&
      [(NSView*)view.window.firstResponder isDescendantOf:view]) {
    [view.window makeFirstResponder:nil];
  }
  view.hidden = !visible;
  [self noteShownByHost:visible && view.window != nil];
  if (visible) [self noteShownInWindow];
}
- (void)detachFromHost {
  NSParameterAssert(NSThread.isMainThread);
  NSView* view = self.view;
  NSResponder* responder = view.window.firstResponder;
  if ([responder isKindOfClass:NSView.class] &&
      [(NSView*)responder isDescendantOf:view]) {
    [view.window makeFirstResponder:nil];
  }
  [self noteShownByHost:NO];
  view.hidden = YES;
  [view removeFromSuperview];
}
@end

namespace {
NSMapTable<AircWindow*, NSView*>* Anchors() {
  static NSMapTable* anchors = [NSMapTable weakToWeakObjectsMapTable];
  return anchors;
}
}
@interface AircActionPanel : NSObject <NSWindowDelegate>
@property NSPanel* panel;
@property AircTab* tab;
@end
@implementation AircActionPanel
- (void)windowWillClose:(NSNotification*)notification { [self.tab close]; self.tab = nil; }
- (void)dealloc { [self.tab close]; [self.panel orderOut:nil]; }
@end
static char kActionPanel;
static char kAnchorRect;
@implementation AircWindow (Hosting)
- (NSView*)uiAnchorView { return [Anchors() objectForKey:self] ?: self.hostView; }
- (void)setUiAnchorView:(NSView*)view {
  objc_setAssociatedObject(self, &kAnchorRect, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  if (view) [Anchors() setObject:view forKey:self];
  else [Anchors() removeObjectForKey:self];
}
- (NSRect)uiAnchorRect {
  NSValue* value = objc_getAssociatedObject(self, &kAnchorRect);
  return value ? value.rectValue : self.uiAnchorView.bounds;
}
- (void)setUiAnchorRect:(NSRect)rect {
  objc_setAssociatedObject(self, &kAnchorRect, [NSValue valueWithRect:rect], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (NSRect)uiAnchorRectInScreen {
  NSView* anchor = self.uiAnchorView;
  if (anchor.window != self.window) return NSZeroRect;
  return [anchor.window convertRectToScreen:[anchor convertRect:self.uiAnchorRect toView:nil]];
}
- (void)closeActionPopup {
  AircActionPanel* controller = objc_getAssociatedObject(self, &kActionPanel);
  [controller.panel close];
  objc_setAssociatedObject(self, &kActionPanel, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (AircTab*)openExtensionsPageForProfile:(AircProfile*)profile {
  return [self openTab:@"chrome://extensions/" profile:profile foreground:YES];
}
- (AircTab*)openWebStoreForProfile:(AircProfile*)profile {
  return [self openTab:@"https://chromewebstore.google.com/" profile:profile foreground:YES];
}
- (AircTab*)presentActionPopupForExtension:(NSString*)extensionID tab:(AircTab*)tab
    anchorRect:(NSRect)rect inView:(NSView*)view {
  if (view.window != self.window || !NSEqualRects(NSIntersectionRect(rect, view.bounds), rect)) return nil;
  [self closeActionPopup];
  AircTab* popup = [self openActionPopupForExtension:extensionID tab:tab];
  if (!popup) return nil;
  NSRect anchor = [view.window convertRectToScreen:[view convertRect:rect toView:nil]];
  NSSize size = popup.preferredSize;
  if (size.width < 25 || size.height < 25) size = NSMakeSize(360, 480);
  size.width = MIN(size.width, 800); size.height = MIN(size.height, 600);
  NSRect frame = NSMakeRect(NSMinX(anchor), NSMinY(anchor)-size.height, size.width, size.height);
  NSRect screen = view.window.screen.visibleFrame;
  frame.origin.x = MAX(NSMinX(screen), MIN(frame.origin.x, NSMaxX(screen)-size.width));
  frame.origin.y = MAX(NSMinY(screen), MIN(frame.origin.y, NSMaxY(screen)-size.height));
  AircActionPanel* controller = [AircActionPanel new];
  controller.tab = popup;
  controller.panel = [[NSPanel alloc] initWithContentRect:frame
      styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskNonactivatingPanel
      backing:NSBackingStoreBuffered defer:NO];
  controller.panel.title = @"Extension";
  controller.panel.becomesKeyOnlyIfNeeded = YES;
  controller.panel.releasedWhenClosed = NO;
  controller.panel.delegate = controller;
  [popup attachToView:controller.panel.contentView];
  objc_setAssociatedObject(self, &kActionPanel, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [self.window addChildWindow:controller.panel ordered:NSWindowAbove];
  [controller.panel orderWindow:NSWindowAbove relativeTo:self.window.windowNumber];
  return popup;
}
- (AircTab*)openActionPopupForExtension:(NSString*)extensionID tab:(AircTab*)tab {
  if (tab.closed || !tab.profile || ![[self tabsForProfile:tab.profile] containsObject:tab]) return nil;
  if (![[tab executeExtensionAction:extensionID] isEqualToString:@"popup"]) return nil;
  NSString* url = [tab actionStatesForExtensions:@[extensionID]][extensionID][@"popup"];
  return url.length ? [self openExtensionView:url profile:tab.profile kind:@"popup"] : nil;
}
@end

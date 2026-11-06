// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// Included by airc_picture_in_picture.mm, outside any namespace.
// Chromium supplies the AppKit half of panel behavior, but not the WindowServer
// activation tag normally installed by NSPanel's initializer. Keep this SPI
// narrow and guarded; never change an existing window's Objective-C class.
@interface NSWindow (AircPipActivationTag)
- (void)_setPreventsActivation:(BOOL)preventsActivation;
@end

@interface AircPipPointer : NSObject
@property(nonatomic, weak) NSWindow* window;
@property(nonatomic, weak) NSView* controlView;
@property(nonatomic, strong) NSMutableArray<NSEvent*>* pending;
@property(nonatomic, strong) NSEvent* down;
@property(nonatomic) NSRect startFrame;
@property(nonatomic) NSPoint startPoint;
@property(nonatomic) NSPoint lastPoint;
@property(nonatomic) NSPoint velocity;
@property(nonatomic) NSTimeInterval lastTime;
@property(nonatomic) BOOL dragging;
@property(nonatomic) BOOL replaying;
@property(nonatomic) BOOL freePlacement;
@property(nonatomic) BOOL overlayBackground;
@property(nonatomic) NSUInteger generation;
- (BOOL)event:(NSEvent*)event;
- (void)forwardControl:(NSEvent*)event;
- (void)resolveBackground:(BOOL)background generation:(NSUInteger)generation;
@end

namespace airc {
namespace {
const char kPipPointer = 0;
// The app's hosted overlay view (InstallAppOverlay), associated with the window.
const char kPipOverlay = 0;
// 0: not on the overlay; 1: on one of its controls (`control`); 2: its own drag
// background. Asked directly: BridgedContentView's hitTest: answers a draggable
// background before it looks at its subviews.
int AppOverlayHit(NSWindow* window, NSPoint inWindow, NSView* __strong* control) {
  NSView* overlay = objc_getAssociatedObject(window, &kPipOverlay);
  if (!overlay || overlay.hidden || overlay.window != window || !overlay.superview) return 0;
  NSView* hit = [overlay hitTest:[overlay.superview convertPoint:inWindow fromView:nil]];
  if (control) *control = hit;
  return !hit ? 0 : hit == overlay ? 2 : 1;
}
void ConfigurePipWindow(NSWindow* window) {
  if (![window isKindOfClass:NativeWidgetMacNSWindow.class]) return;
  // Chromium's supported panel-equivalent mode. Preserve its bridge, frame,
  // command dispatcher and accessibility implementation; no class swizzling.
  [(NativeWidgetMacNSWindow*)window setActivationIndependence:YES];
  if ([window respondsToSelector:@selector(_setPreventsActivation:)])
    [window _setPreventsActivation:YES];
  window.hidesOnDeactivate = NO;
  window.level = NSFloatingWindowLevel;
  auto behavior = window.collectionBehavior;
  behavior &= ~(NSWindowCollectionBehaviorMoveToActiveSpace |
                NSWindowCollectionBehaviorFullScreenPrimary |
                NSWindowCollectionBehaviorManaged |
                NSWindowCollectionBehaviorTransient |
                NSWindowCollectionBehaviorParticipatesInCycle);
  behavior |= NSWindowCollectionBehaviorCanJoinAllSpaces |
              NSWindowCollectionBehaviorFullScreenAuxiliary |
              NSWindowCollectionBehaviorStationary |
              NSWindowCollectionBehaviorIgnoresCycle;
  if (@available(macOS 13.0, *)) {
    behavior &= ~(NSWindowCollectionBehaviorPrimary | NSWindowCollectionBehaviorAuxiliary);
    behavior |= NSWindowCollectionBehaviorCanJoinAllApplications;
  }
  window.collectionBehavior = behavior;
  if (!objc_getAssociatedObject(window, &kPipPointer)) {
    AircPipPointer* pointer = [AircPipPointer new];
    pointer.window = window;
    objc_setAssociatedObject(window, &kPipPointer, pointer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
}

void StartPipWindowPolicy() {
  // Runs before Show(), for both kinds, rather than only the posted placement.
  static base::NoDestructor<base::CallbackListSubscription> subscription(
      views::NativeWidgetMac::RegisterInitNativeWidgetCallback(base::BindRepeating(
          [](views::NativeWidgetMac* native) {
            if (!SwitchOn("pipPlacement")) return;
            auto* widget = native->GetWidget();
            bool pip = widget->GetName() == "PictureInPictureWindow";
            if (widget->GetName() == "BrowserWidget") {
              auto* view = static_cast<BrowserView*>(widget->widget_delegate());
              pip = view->browser()->GetType() == BrowserWindowInterface::TYPE_PICTURE_IN_PICTURE;
            }
            if (pip) ConfigurePipWindow(native->GetNativeWindow().GetNativeNSWindow());
          })));
  g_airc_pip_nonactivating = [](NSWindow* window) {
    return objc_getAssociatedObject(window, &kPipPointer) != nil;
  };
  g_airc_pip_window_event = [](NSWindow* window, NSEvent* event) {
    AircPipPointer* pointer = objc_getAssociatedObject(window, &kPipPointer);
    return pointer && [pointer event:event];
  };
}
}  // namespace
}  // namespace airc

@implementation AircPipPointer
@synthesize controlView = _controlView;
@synthesize window = _window, pending = _pending, down = _down;
@synthesize startFrame = _startFrame, startPoint = _startPoint, lastPoint = _lastPoint;
@synthesize velocity = _velocity, lastTime = _lastTime, dragging = _dragging;
@synthesize replaying = _replaying, freePlacement = _freePlacement, generation = _generation;
@synthesize overlayBackground = _overlayBackground;
- (NSPoint)screenPoint:(NSEvent*)event {
  return [self.window convertPointToScreen:event.locationInWindow];
}
- (void)resolveBackground:(BOOL)background generation:(NSUInteger)generation {
  if (generation != self.generation || !self.window) return;
  NSArray<NSEvent*>* events = self.pending;
  self.pending = nil;
  if (background) {
    // Queued events were recorded before the first move. Rebase each one from
    // that frame, otherwise replaying several drags adds the window's motion
    // to the pointer's motion a second time.
    NSPoint origin = self.window.frame.origin;
    for (NSEvent* event in events) {
      NSPoint screen = NSMakePoint(origin.x+event.locationInWindow.x,
                                    origin.y+event.locationInWindow.y);
      NSEvent* rebased = [NSEvent mouseEventWithType:event.type
          location:[self.window convertPointFromScreen:screen]
          modifierFlags:event.modifierFlags timestamp:event.timestamp
          windowNumber:event.windowNumber context:nil eventNumber:event.eventNumber
          clickCount:event.clickCount pressure:event.pressure];
      [self event:rebased];
    }
  } else {
    self.down = nil;
    self.replaying = YES;
    for (NSEvent* event in events) [self forwardControl:event];
    self.replaying = NO;
  }
}
- (void)forwardControl:(NSEvent*)event {
  // NSWindow's inactive first-click dispatch activates even an activation-
  // independent Chromium window for in-process events. Send the already
  // hit-tested sequence to its native content receiver, retaining Views/renderer
  // control handling without asking NSWindow to activate the application.
  if (event.type == NSEventTypeLeftMouseDown) {
    NSView* root = self.window.contentView;
    self.controlView = [root hitTest:[root.superview convertPoint:event.locationInWindow fromView:nil]];
  }
  NSView* target = self.controlView;
  if (event.type == NSEventTypeLeftMouseDown) [target mouseDown:event];
  else if (event.type == NSEventTypeLeftMouseDragged) [target mouseDragged:event];
  else if (event.type == NSEventTypeLeftMouseUp) {
    self.controlView = nil;
    [target mouseUp:event];
  }
}
- (BOOL)event:(NSEvent*)event {
  if (self.replaying) return NO;
  NSEventType type = event.type;
  if (type != NSEventTypeLeftMouseDown && type != NSEventTypeLeftMouseDragged &&
      type != NSEventTypeLeftMouseUp) return NO;
  if (self.pending) { [self.pending addObject:event]; return YES; }
  if (self.controlView && type != NSEventTypeLeftMouseDown) { [self forwardControl:event]; return YES; }
  NSWindow* window = self.window;
  if (type == NSEventTypeLeftMouseDown) {
    self.generation++;
    self.dragging = NO;
    self.down = nil;
    self.overlayBackground = NO;
    NSPoint p = event.locationInWindow;
    // The app's controls get the whole press directly (forwardControl), active
    // or not, so a click never activates Airc and a scrubber keeps its drag.
    NSView* control = nil;
    int overlay = airc::AppOverlayHit(window, p, &control);
    if (overlay == 1) {
      self.controlView = control;
      [control mouseDown:event];
      return YES;
    }
    // Keep native resize edges and Views controls. A video background returns
    // HTCAPTION; Document PiP's web content returns HTCLIENT.
    if (!NSPointInRect(p, NSInsetRect(NSMakeRect(0, 0, window.frame.size.width,
                                                window.frame.size.height), 8, 8))) return NO;
    auto* widget = views::Widget::GetWidgetForNativeWindow(gfx::NativeWindow(window));
    if (!widget || !widget->non_client_view()) return NO;
    int hit = widget->non_client_view()->NonClientHitTest(
        gfx::Point(p.x, window.frame.size.height - p.y));
    auto* child = PictureInPictureWindowManager::GetInstance()->GetChildWebContents();
    NSView* page = child ? child->GetNativeView().GetNativeNSView() : nil;
    NSPoint inPage = page ? [page convertPoint:p fromView:nil] : NSZeroPoint;
    bool web = page && page.window == window && NSPointInRect(inPage, page.bounds);
    // The overlay's own background (a Document PiP top bar) only moves the
    // window; Chromium's controls under it never see the press.
    if (overlay == 2) { hit = HTCAPTION; web = false; self.overlayBackground = YES; }
    if (hit != HTCAPTION && !web) {
      if ((hit == HTCLIENT || hit == HTNOWHERE) && !NSApp.active) { [self forwardControl:event]; return YES; }
      return NO;
    }
    // A press during the corner spring takes the window where it is now;
    // otherwise the running animation keeps pulling it back to the corner.
    window.animations = @{};
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
      context.duration = 0;
      [[window animator] setFrame:window.frame display:NO];
    } completionHandler:nil];
    self.down = event;
    self.startFrame = window.frame;
    self.startPoint = [self screenPoint:event];
    self.lastPoint = self.startPoint;
    self.lastTime = event.timestamp;
    self.velocity = NSZeroPoint;
    self.freePlacement = (event.modifierFlags & NSEventModifierFlagCommand) != 0;
    if (web) {
      // Hit-test in an isolated world, so page overrides cannot consume controls.
      // Unknown results, subframes, editable/interactive/custom controls fail
      // closed to Chromium. No overlay view covers the site's controls.
      self.pending = [NSMutableArray arrayWithObject:event];
      double x = inPage.x / page.bounds.size.width;
      double y = (page.flipped ? inPage.y : page.bounds.size.height-inPage.y) / page.bounds.size.height;
      std::string js = base::StringPrintf(
          "(()=>{const x=%f*innerWidth,y=%f*innerHeight;let e=document.elementFromPoint(x,y);if(!e)return false;"
          "while(e&&e.shadowRoot){let inner=e.shadowRoot.elementFromPoint(x,y);if(!inner||inner===e)break;e=inner;}"
          "while(e){if(e.matches('button,a,input,textarea,select,iframe,[role],[tabindex],[draggable=true]')"
          "||e.isContentEditable||e.onclick||e.onmousedown||e.onpointerdown||"
          "(e.tagName==='VIDEO'&&e.controls))return false;e=e.parentElement||e.getRootNode().host}return true})()", x, y);
      __weak AircPipPointer* weak = self;
      NSUInteger generation = self.generation;
      child->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
          base::UTF8ToUTF16(js), base::BindOnce([](__weak AircPipPointer* pointer,
              NSUInteger gen, base::Value value) {
            // Remove the already-recorded down; its state is initialized above.
            if (pointer.generation == gen && value.is_bool() && value.GetBool())
              [pointer.pending removeObjectAtIndex:0];
            [pointer resolveBackground:value.is_bool() && value.GetBool() generation:gen];
          }, weak, generation), ISOLATED_WORLD_ID_CHROME_INTERNAL);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (weak.pending && weak.generation == generation)
          [weak resolveBackground:NO generation:generation];
      });
    }
    return YES;
  }
  if (!self.down) return NO;
  NSPoint point = [self screenPoint:event];
  self.freePlacement |= (event.modifierFlags & NSEventModifierFlagCommand) != 0;
  if (type == NSEventTypeLeftMouseDragged) {
    double dx = point.x-self.startPoint.x, dy = point.y-self.startPoint.y;
    if (!self.dragging && hypot(dx, dy) < 3) return YES;
    self.dragging = YES;
    double dt = event.timestamp-self.lastTime;
    if (dt > 0) self.velocity = NSMakePoint((point.x-self.lastPoint.x)/dt,
                                           (point.y-self.lastPoint.y)/dt);
    self.lastTime = event.timestamp;
    self.lastPoint = point;
    [window setFrameOrigin:NSMakePoint(self.startFrame.origin.x+dx, self.startFrame.origin.y+dy)];
    return YES;
  }
  NSEvent* down = self.down;
  self.down = nil;
  if (!self.dragging) {
    if (self.overlayBackground) return YES;
    self.replaying = YES;
    [self forwardControl:down]; [self forwardControl:event];
    self.replaying = NO;
    return YES;
  }
  self.dragging = NO;
  if (self.freePlacement) return YES;
  NSScreen* screen = window.screen ?: NSScreen.mainScreen;
  for (NSScreen* candidate in NSScreen.screens)
    if (NSPointInRect(point, candidate.frame)) { screen = candidate; break; }
  NSRect area = NSInsetRect(screen.visibleFrame, 20, 20);
  NSRect target = window.frame;
  NSPoint projected = NSMakePoint(NSMidX(target), NSMidY(target));
  if (event.timestamp-self.lastTime < 0.12 && hypot(self.velocity.x, self.velocity.y) > 650) {
    projected.x += self.velocity.x * 0.25;
    projected.y += self.velocity.y * 0.25;
  }
  target.origin = NSMakePoint(projected.x < NSMidX(area) ? NSMinX(area) : NSMaxX(area)-target.size.width,
                              projected.y < NSMidY(area) ? NSMinY(area) : NSMaxY(area)-target.size.height);
  CASpringAnimation* spring = [CASpringAnimation animation];
  spring.mass = 1; spring.stiffness = 320; spring.damping = 30;
  spring.initialVelocity = 0;
  spring.duration = spring.settlingDuration;
  window.animations = @{ @"frame": spring };
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext* context) {
    context.duration = spring.settlingDuration;
    [[window animator] setFrame:target display:YES];
  } completionHandler:nil];
  return YES;
}
@end

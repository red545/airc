// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
// A stand-in for the app's PiP controls (engine/PIP.md "App overlay"): a full-size
// view that passes presses through except on its one control and a top band.
// Included at file scope by main.mm.
@interface AircTestPipControl : NSView
@property NSInteger downs, drags, ups;
@end
@implementation AircTestPipControl
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (void)drawRect:(NSRect)dirty { [[NSColor colorWithWhite:1 alpha:0.85] setFill]; NSRectFill(self.bounds); }
// No nested tracking loop: the engine forwards down, drags and up one by one.
- (void)mouseDown:(NSEvent*)event { self.downs++; }
- (void)mouseDragged:(NSEvent*)event { self.drags++; }
- (void)mouseUp:(NSEvent*)event { self.ups++; }
@end

@interface AircTestPipOverlay : NSView
@property AircTestPipControl* control;
@property NSInteger backgroundPresses;
@end
@implementation AircTestPipOverlay
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _control = [[AircTestPipControl alloc] initWithFrame:NSMakeRect(0, 0, 44, 28)];
    [self addSubview:_control];
  }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (void)layout {
  [super layout];
  // Top centre, clear of the background point the drag checks use.
  self.control.frame = NSMakeRect(NSMidX(self.bounds)-22, 12, 44, 28);
}
// Top band is drag background (returns self), the control is a control, the
// rest passes through to Chromium (the video's own drag region).
- (NSView*)hitTest:(NSPoint)point {
  NSPoint p = [self convertPoint:point fromView:self.superview];
  if (!NSPointInRect(p, self.bounds)) return nil;
  if (NSPointInRect(p, self.control.frame)) return self.control;
  // Below the engine's 8-point resize band, like a Document PiP top bar.
  return p.y < 44 ? self : nil;
}
- (void)mouseDown:(NSEvent*)event { self.backgroundPresses++; }
@end

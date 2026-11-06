// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0

import AppKit
let output = CommandLine.arguments[1]
let icon = NSImage(contentsOfFile: CommandLine.arguments[2])!
let image = NSImage(size: NSSize(width: 660, height: 440))
image.lockFocus()
NSGradient(colors: [NSColor(red:0.94,green:0.91,blue:1,alpha:1), NSColor(red:0.87,green:0.96,blue:0.98,alpha:1)])!.draw(in: NSRect(x:0,y:0,width:660,height:440), angle: -25)
icon.draw(in: NSRect(x:302,y:345,width:56,height:56))
func text(_ s:String, _ y:CGFloat, _ size:CGFloat, _ color:NSColor) {
 let a:[NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:size, weight:.medium),.foregroundColor:color]
 let w=(s as NSString).size(withAttributes:a).width
 (s as NSString).draw(at:NSPoint(x:(660-w)/2,y:y),withAttributes:a)
}
text("Make room for your internet.", 304, 25, .darkGray)
text("→", 187, 38, NSColor.darkGray.withAlphaComponent(0.45))
text("Drag Airc to Applications to get started.", 65, 14, .darkGray)
image.unlockFocus()
let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:output))

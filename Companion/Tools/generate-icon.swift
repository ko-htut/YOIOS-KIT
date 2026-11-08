import AppKit

// This source draws the app's own vector icon; no external artwork is used.
let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let bounds = NSRect(x: 0, y: 0, width: size, height: size)
NSGradient(starting: NSColor(red: 0.05, green: 0.34, blue: 0.94, alpha: 1),
           ending: NSColor(red: 0.18, green: 0.67, blue: 1, alpha: 1))!
    .draw(in: bounds, angle: 45)
let phone = NSBezierPath(roundedRect: NSRect(x: 330, y: 205, width: 364, height: 614), xRadius: 74, yRadius: 74)
NSColor.white.withAlphaComponent(0.22).setFill(); phone.fill()
NSColor.white.setStroke(); phone.lineWidth = 29; phone.stroke()
let island = NSBezierPath(roundedRect: NSRect(x: 439, y: 747, width: 146, height: 30), xRadius: 15, yRadius: 15)
NSColor.white.setFill(); island.fill()
let home = NSBezierPath(roundedRect: NSRect(x: 445, y: 244, width: 134, height: 14), xRadius: 7, yRadius: 7)
home.fill()
let pin = NSBezierPath()
pin.move(to: NSPoint(x: 512, y: 360))
pin.curve(to: NSPoint(x: 398, y: 563), controlPoint1: NSPoint(x: 480, y: 406), controlPoint2: NSPoint(x: 398, y: 497))
pin.curve(to: NSPoint(x: 626, y: 563), controlPoint1: NSPoint(x: 398, y: 715), controlPoint2: NSPoint(x: 626, y: 715))
pin.curve(to: NSPoint(x: 512, y: 360), controlPoint1: NSPoint(x: 626, y: 497), controlPoint2: NSPoint(x: 544, y: 406))
pin.close(); pin.fill()
NSColor(red: 0.08, green: 0.48, blue: 0.96, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 474, y: 546, width: 76, height: 76)).fill()
NSGraphicsContext.restoreGraphicsState()
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))

import AppKit

let size = NSSize(width: 1024, height: 1024)
guard let cg = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
                         bytesPerRow: 4096, space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("Cannot create icon canvas") }
let context = NSGraphicsContext(cgContext: cg, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
NSColor(srgbRed: 0.22, green: 0.37, blue: 0.58, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
let paper = NSBezierPath(roundedRect: NSRect(x: 268, y: 190, width: 504, height: 644), xRadius: 42, yRadius: 42)
NSColor(srgbRed: 0.98, green: 0.97, blue: 0.94, alpha: 1).setFill()
paper.fill()
NSColor(srgbRed: 0.86, green: 0.87, blue: 0.86, alpha: 1).setStroke()
for y in [350, 430, 510, 590, 670] {
    let line = NSBezierPath()
    line.move(to: NSPoint(x: 350, y: y))
    line.line(to: NSPoint(x: 688, y: y))
    line.lineWidth = 4
    line.stroke()
}
let ink = NSBezierPath()
ink.move(to: NSPoint(x: 352, y: 360))
ink.curve(to: NSPoint(x: 520, y: 570), controlPoint1: NSPoint(x: 560, y: 270), controlPoint2: NSPoint(x: 635, y: 735))
ink.curve(to: NSPoint(x: 683, y: 429), controlPoint1: NSPoint(x: 398, y: 397), controlPoint2: NSPoint(x: 524, y: 314))
ink.lineWidth = 19
ink.lineCapStyle = .round
NSColor(srgbRed: 0.22, green: 0.37, blue: 0.58, alpha: 1).setStroke()
ink.stroke()
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let result = cg.makeImage(),
      let png = NSBitmapImageRep(cgImage: result).representation(using: .png, properties: [:]) else { fatalError("Cannot render app icon") }
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

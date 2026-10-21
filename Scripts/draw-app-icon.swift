import AppKit

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size: CGFloat = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let context = NSGraphicsContext(bitmapImageRep: bitmap)!
NSGraphicsContext.current = context
context.imageInterpolation = .high

let iconRect = NSRect(x: 18, y: 18, width: size - 36, height: size - 36)
let background = NSBezierPath(roundedRect: iconRect, xRadius: 220, yRadius: 220)
NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.23, blue: 0.34, alpha: 1),
    NSColor(calibratedRed: 0.055, green: 0.085, blue: 0.15, alpha: 1)
])!.draw(in: background, angle: 90)

let highlight = NSBezierPath(roundedRect: NSRect(x: 36, y: 36, width: size - 72, height: size - 72), xRadius: 204, yRadius: 204)
NSColor.white.withAlphaComponent(0.16).setStroke()
highlight.lineWidth = 5
highlight.stroke()

let barBase: CGFloat = 280
let bars: [(CGFloat, CGFloat, NSColor, NSColor)] = [
    (232, 282, NSColor(calibratedRed: 0.36, green: 0.82, blue: 0.97, alpha: 1), NSColor(calibratedRed: 0.23, green: 0.53, blue: 0.93, alpha: 1)),
    (456, 470, NSColor(calibratedRed: 0.54, green: 0.88, blue: 0.98, alpha: 1), NSColor(calibratedRed: 0.29, green: 0.65, blue: 0.96, alpha: 1)),
    (680, 354, NSColor(calibratedRed: 0.42, green: 0.84, blue: 0.94, alpha: 1), NSColor(calibratedRed: 0.26, green: 0.59, blue: 0.91, alpha: 1))
]

for (x, height, top, bottom) in bars {
    let bar = NSBezierPath(roundedRect: NSRect(x: x, y: barBase, width: 112, height: height), xRadius: 56, yRadius: 56)
    NSGradient(colors: [bottom, top])!.draw(in: bar, angle: 90)
    NSColor.white.withAlphaComponent(0.24).setStroke()
    bar.lineWidth = 3
    bar.stroke()
}

let baseline = NSBezierPath()
baseline.move(to: NSPoint(x: 184, y: 230))
baseline.line(to: NSPoint(x: 840, y: 230))
baseline.lineCapStyle = .round
NSColor.white.withAlphaComponent(0.28).setStroke()
baseline.lineWidth = 10
baseline.stroke()

NSGraphicsContext.restoreGraphicsState()
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: outputURL)

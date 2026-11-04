import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "work/Newline.iconset")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func renderIcon(size: Int, name: String) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880),
                                  xRadius: 196, yRadius: 196)
    NSColor(calibratedRed: 0.105, green: 0.115, blue: 0.135, alpha: 1).setFill()
    background.fill()
    NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
    background.lineWidth = 3
    background.stroke()

    // Two text lines followed by a return stroke: the start of a new thought.
    let lines = NSBezierPath()
    lines.lineWidth = 53
    lines.lineCapStyle = .round
    lines.move(to: NSPoint(x: 300, y: 672))
    lines.line(to: NSPoint(x: 724, y: 672))
    lines.move(to: NSPoint(x: 300, y: 517))
    lines.line(to: NSPoint(x: 530, y: 517))
    NSColor(calibratedWhite: 0.96, alpha: 1).setStroke()
    lines.stroke()

    let arrow = NSBezierPath()
    arrow.lineWidth = 53
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 724, y: 517))
    arrow.line(to: NSPoint(x: 724, y: 365))
    arrow.curve(to: NSPoint(x: 675, y: 316), controlPoint1: NSPoint(x: 724, y: 338), controlPoint2: NSPoint(x: 702, y: 316))
    arrow.line(to: NSPoint(x: 340, y: 316))
    arrow.move(to: NSPoint(x: 410, y: 386))
    arrow.line(to: NSPoint(x: 340, y: 316))
    arrow.line(to: NSPoint(x: 410, y: 246))
    NSColor(calibratedRed: 0.55, green: 0.84, blue: 0.76, alpha: 1).setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}

for points in [16, 32, 128, 256, 512] {
    try renderIcon(size: points, name: "icon_\(points)x\(points).png")
    try renderIcon(size: points * 2, name: "icon_\(points)x\(points)@2x.png")
}

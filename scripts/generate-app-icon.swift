#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-app-icon.swift <output.icns>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let temporaryIconset = FileManager.default.temporaryDirectory
    .appendingPathComponent("BrowserLens-\(UUID().uuidString).iconset", isDirectory: true)

try FileManager.default.createDirectory(
    at: temporaryIconset,
    withIntermediateDirectories: true
)
defer { try? FileManager.default.removeItem(at: temporaryIconset) }

let iconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for iconSize in iconSizes {
    let image = drawBrowserLensIcon(pixels: iconSize.pixels)
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        fputs("failed to render \(iconSize.name)\n", stderr)
        exit(1)
    }
    try png.write(to: temporaryIconset.appendingPathComponent(iconSize.name))
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", outputURL.path, temporaryIconset.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus != 0 {
    fputs("iconutil failed\n", stderr)
    exit(process.terminationStatus)
}

func drawBrowserLensIcon(pixels: Int) -> NSImage {
    let size = NSSize(width: pixels, height: pixels)
    let image = NSImage(size: size)
    image.lockFocus()
    defer { image.unlockFocus() }

    let rect = NSRect(origin: .zero, size: size)
    NSColor.clear.setFill()
    rect.fill()

    let cornerRadius = CGFloat(pixels) * 0.22
    let backgroundPath = NSBezierPath(roundedRect: rect.insetBy(dx: CGFloat(pixels) * 0.045, dy: CGFloat(pixels) * 0.045), xRadius: cornerRadius, yRadius: cornerRadius)
    let gradient = NSGradient(colors: [
        NSColor(red: 0.05, green: 0.09, blue: 0.18, alpha: 1),
        NSColor(red: 0.04, green: 0.45, blue: 0.52, alpha: 1)
    ])
    gradient?.draw(in: backgroundPath, angle: 315)

    let glowPath = NSBezierPath(ovalIn: NSRect(
        x: CGFloat(pixels) * 0.16,
        y: CGFloat(pixels) * 0.16,
        width: CGFloat(pixels) * 0.68,
        height: CGFloat(pixels) * 0.68
    ))
    NSColor(red: 0.68, green: 0.95, blue: 1.0, alpha: 0.18).setFill()
    glowPath.fill()

    drawMemoryLines(pixels: pixels)

    let lensRect = NSRect(
        x: CGFloat(pixels) * 0.24,
        y: CGFloat(pixels) * 0.35,
        width: CGFloat(pixels) * 0.42,
        height: CGFloat(pixels) * 0.42
    )
    let lensPath = NSBezierPath(ovalIn: lensRect)
    NSColor(red: 0.92, green: 0.99, blue: 1.0, alpha: 0.94).setStroke()
    lensPath.lineWidth = max(2, CGFloat(pixels) * 0.055)
    lensPath.stroke()

    let handle = NSBezierPath()
    handle.move(to: NSPoint(x: CGFloat(pixels) * 0.61, y: CGFloat(pixels) * 0.38))
    handle.line(to: NSPoint(x: CGFloat(pixels) * 0.77, y: CGFloat(pixels) * 0.22))
    handle.lineCapStyle = .round
    handle.lineWidth = max(2, CGFloat(pixels) * 0.07)
    NSColor(red: 0.92, green: 0.99, blue: 1.0, alpha: 0.94).setStroke()
    handle.stroke()

    let pupil = NSBezierPath(ovalIn: NSRect(
        x: CGFloat(pixels) * 0.38,
        y: CGFloat(pixels) * 0.49,
        width: CGFloat(pixels) * 0.14,
        height: CGFloat(pixels) * 0.14
    ))
    NSColor(red: 0.11, green: 0.20, blue: 0.31, alpha: 1).setFill()
    pupil.fill()

    return image
}

func drawMemoryLines(pixels: Int) {
    let lineWidth = max(1.0, CGFloat(pixels) * 0.018)
    let lineColor = NSColor(red: 1.0, green: 0.82, blue: 0.38, alpha: 0.85)
    let nodeColor = NSColor(red: 1.0, green: 0.82, blue: 0.38, alpha: 0.95)
    let points = [
        NSPoint(x: CGFloat(pixels) * 0.25, y: CGFloat(pixels) * 0.28),
        NSPoint(x: CGFloat(pixels) * 0.34, y: CGFloat(pixels) * 0.72),
        NSPoint(x: CGFloat(pixels) * 0.69, y: CGFloat(pixels) * 0.68),
        NSPoint(x: CGFloat(pixels) * 0.76, y: CGFloat(pixels) * 0.33)
    ]

    let path = NSBezierPath()
    path.move(to: points[0])
    points.dropFirst().forEach { path.line(to: $0) }
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    path.lineWidth = lineWidth
    lineColor.setStroke()
    path.stroke()

    for point in points {
        let radius = CGFloat(pixels) * 0.035
        let nodeRect = NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        nodeColor.setFill()
        NSBezierPath(ovalIn: nodeRect).fill()
    }
}

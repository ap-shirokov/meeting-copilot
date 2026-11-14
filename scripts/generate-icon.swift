#!/usr/bin/swift
import AppKit
import Foundation

// Vector artwork for Meeting Copilot. Rendered at 1024px for crisp .icns output.
let size = 1024
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
let context = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

let tile = NSBezierPath(roundedRect: NSRect(x: 68, y: 68, width: 888, height: 888),
                        xRadius: 205, yRadius: 205)

let shadow = NSShadow()
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 32
shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.20)
shadow.set()
NSColor(calibratedRed: 0.035, green: 0.15, blue: 0.18, alpha: 1).setFill()
tile.fill()
NSShadow().set()

NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.37, blue: 0.39, alpha: 1),
           ending: NSColor(calibratedRed: 0.027, green: 0.11, blue: 0.15, alpha: 1))!
    .draw(in: tile, angle: -52)

NSColor(calibratedRed: 0.35, green: 0.95, blue: 0.88, alpha: 0.28).setStroke()
tile.lineWidth = 5
tile.stroke()

// Nine rounded cyan waveform bars; matched to the icon used in the app sidebar.
let barHeights: [CGFloat] = [52, 98, 178, 278, 362, 278, 178, 98, 52]
let barWidth: CGFloat = 37
let gap: CGFloat = 20
let total = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
let left = (CGFloat(size) - total) / 2
for (index, height) in barHeights.enumerated() {
    let rect = NSRect(x: left + CGFloat(index) * (barWidth + gap),
                      y: (CGFloat(size) - height) / 2,
                      width: barWidth, height: height)
    let bar = NSBezierPath(roundedRect: rect, xRadius: barWidth/2, yRadius: barWidth/2)
    let glow = NSShadow()
    glow.shadowBlurRadius = 22
    glow.shadowColor = NSColor(calibratedRed: 0.18, green: 1, blue: 0.78, alpha: 0.48)
    glow.set()
    NSColor(calibratedRed: 0.23, green: 0.98, blue: 0.79, alpha: 1).setFill()
    bar.fill()
    NSShadow().set()
    NSGradient(starting: NSColor(calibratedRed: 0.58, green: 1.0, blue: 0.9, alpha: 1),
               ending: NSColor(calibratedRed: 0.12, green: 0.88, blue: 0.71, alpha: 1))!
        .draw(in: bar, angle: -90)
}
context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to render icon\n", stderr)
    exit(1)
}
let destination = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/MeetingCopilotIcon.png"
try FileManager.default.createDirectory(at: URL(fileURLWithPath: destination).deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
try png.write(to: URL(fileURLWithPath: destination))
print("Icon rendered at 1024x1024: \(destination)")

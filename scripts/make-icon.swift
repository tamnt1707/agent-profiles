#!/usr/bin/env swift
//
// Generates the app icon of Agent Profiles.
//
//   swift scripts/make-icon.swift <out-dir>
//
// It draws a 1024×1024 macOS style icon (rounded square with a continuous
// corner, a warm terracotta gradient and a white terminal prompt on a front
// card), writes a complete AppIcon.iconset and turns it into an .icns file
// with iconutil. Nothing is downloaded, everything is drawn with CoreGraphics.
//
// Outputs:
//   <out-dir>/AppIcon.iconset/
//   <out-dir>/AppIcon.icns
//   <out-dir>/icon-preview.png   (the 1024 px master)

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: swift scripts/make-icon.swift <out-dir>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// MARK: - Geometry

/// The master size of the icon.
let masterSize: CGFloat = 1024

/// The icon is drawn on a transparent canvas; the rounded square leaves a
/// margin of about 10 % on every side.
let margin: CGFloat = masterSize * 0.10
let bodySide = masterSize - margin * 2

/// Corner radius of the macOS icon shape (~22.37 % of the master size).
let cornerRadius = masterSize * 0.2237

/// A superellipse (n = 5) is the continuous corner of the macOS icons.
func squirclePath(side: CGFloat, center: NSPoint, exponent: CGFloat = 5) -> NSBezierPath {
    let a = side / 2
    let path = NSBezierPath()
    let steps = 360
    for index in 0...steps {
        let t = CGFloat(index) / CGFloat(steps) * 2 * .pi
        let ct = cos(t)
        let st = sin(t)
        let x = a * pow(abs(ct), 2 / exponent) * (ct < 0 ? -1 : 1)
        let y = a * pow(abs(st), 2 / exponent) * (st < 0 ? -1 : 1)
        let point = NSPoint(x: center.x + x, y: center.y + y)
        if index == 0 {
            path.move(to: point)
        } else {
            path.line(to: point)
        }
    }
    path.close()
    return path
}

func roundedRect(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

// MARK: - Drawing

/// Draws the whole icon into a bitmap of the given size.
func renderIcon(size: CGFloat) -> NSBitmapImageRep {
    let scale = size / masterSize
    guard let rep = NSBitmapImageRep(
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
    ) else {
        fatalError("cannot create a bitmap of \(size) points")
    }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)

    let canvas = NSRect(x: 0, y: 0, width: masterSize, height: masterSize)
    NSColor.clear.setFill()
    canvas.fill()

    let center = NSPoint(x: masterSize / 2, y: masterSize / 2)

    // The rounded square with a soft drop shadow.
    let body = squirclePath(side: bodySide, center: center)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = masterSize * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -masterSize * 0.018)
    shadow.set()

    let gradient = NSGradient(colors: [
        NSColor(red: 0.878, green: 0.478, blue: 0.373, alpha: 1),   // #E07A5F
        NSColor(red: 0.710, green: 0.267, blue: 0.165, alpha: 1),   // #B5442A
    ])!
    gradient.draw(in: body, angle: -52)

    NSGraphicsContext.current?.cgContext.saveGState()
    NSShadow().set()

    // Two cards behind the front one: they suggest "several profiles".
    let cardSize = NSSize(width: masterSize * 0.545, height: masterSize * 0.395)
    let cardRadius = cardSize.width * 0.14

    func cardRect(offsetX: CGFloat, offsetY: CGFloat) -> NSRect {
        NSRect(
            x: center.x - cardSize.width / 2 + offsetX,
            y: center.y - cardSize.height / 2 + offsetY,
            width: cardSize.width,
            height: cardSize.height
        )
    }

    let backCard = roundedRect(cardRect(offsetX: -masterSize * 0.062, offsetY: -masterSize * 0.030), radius: cardRadius)
    NSColor.white.withAlphaComponent(0.20).setFill()
    backCard.fill()

    let middleCard = roundedRect(cardRect(offsetX: -masterSize * 0.028, offsetY: -masterSize * 0.010), radius: cardRadius)
    NSColor.white.withAlphaComponent(0.32).setFill()
    middleCard.fill()

    // The front card: a dark terminal window on top of the gradient.
    let frontRect = cardRect(offsetX: 0, offsetY: 0)
    let frontCard = roundedRect(frontRect, radius: cardRadius)
    NSColor.black.withAlphaComponent(0.26).setFill()
    frontCard.fill()
    NSColor.white.withAlphaComponent(0.16).setStroke()
    frontCard.lineWidth = masterSize * 0.005
    frontCard.stroke()

    // The prompt: a ">" chevron and an underscore cursor.
    let chevronWidth = masterSize * 0.115
    let chevronHeight = masterSize * 0.160
    let chevronLeft = frontRect.minX + masterSize * 0.090
    let chevronMiddleY = frontRect.midY + masterSize * 0.028

    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: chevronLeft, y: chevronMiddleY + chevronHeight / 2))
    chevron.line(to: NSPoint(x: chevronLeft + chevronWidth, y: chevronMiddleY))
    chevron.line(to: NSPoint(x: chevronLeft, y: chevronMiddleY - chevronHeight / 2))
    chevron.lineWidth = masterSize * 0.052
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    NSColor.white.setStroke()
    chevron.stroke()

    // The cursor sits on the same line, right of the chevron.
    let cursor = roundedRect(
        NSRect(
            x: chevronLeft + chevronWidth + masterSize * 0.055,
            y: chevronMiddleY - chevronHeight / 2,
            width: masterSize * 0.150,
            height: masterSize * 0.046
        ),
        radius: masterSize * 0.023
    )
    NSColor.white.setFill()
    cursor.fill()

    NSGraphicsContext.current?.cgContext.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data {
    rep.representation(using: .png, properties: [:])!
}

// MARK: - Iconset

let iconset = outDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// Every size of the iconset: (file name, point size, scale).
let entries: [(name: String, points: Int, scale: Int)] = [
    ("icon_16x16", 16, 1),
    ("icon_16x16@2x", 16, 2),
    ("icon_32x32", 32, 1),
    ("icon_32x32@2x", 32, 2),
    ("icon_128x128", 128, 1),
    ("icon_128x128@2x", 128, 2),
    ("icon_256x256", 256, 1),
    ("icon_256x256@2x", 256, 2),
    ("icon_512x512", 512, 1),
    ("icon_512x512@2x", 512, 2),
]

for entry in entries {
    let rep = renderIcon(size: CGFloat(entry.points * entry.scale))
    let data = png(rep)
    try data.write(to: iconset.appendingPathComponent("\(entry.name).png"))
}

// The master image.
let master = renderIcon(size: masterSize)
try png(master).write(to: outDir.appendingPathComponent("icon-preview.png"))

let contents: [[String: Any]] = entries.map { entry in
    [
        "size": "\(entry.points)x\(entry.points)",
        "idiom": "mac",
        "filename": "\(entry.name).png",
        "scale": "\(entry.scale)x",
    ]
}
let contentsData = try JSONSerialization.data(withJSONObject: ["images": contents], options: [.prettyPrinted, .sortedKeys])
try contentsData.write(to: iconset.appendingPathComponent("Contents.json"))

// MARK: - icns

let icns = outDir.appendingPathComponent("AppIcon.icns")
try? FileManager.default.removeItem(at: icns)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}

print("Wrote \(iconset.path)")
print("Wrote \(icns.path)")
print("Wrote \(outDir.appendingPathComponent("icon-preview.png").path)")

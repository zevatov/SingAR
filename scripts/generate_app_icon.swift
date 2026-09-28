import Foundation
import AppKit
import CoreGraphics

let size = NSSize(width: 1024, height: 1024)
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size.width),
    pixelsHigh: Int(size.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!
rep.size = size

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx

let cgCtx = ctx.cgContext

// Squircle parameters (Apple standard icon grid: 824x824 inside 1024x1024 canvas with shadow)
let iconInset: CGFloat = 100
let iconRect = NSRect(x: iconInset, y: iconInset, width: size.width - iconInset * 2, height: size.height - iconInset * 2)
let cornerRadius: CGFloat = 185

// Drop Shadow behind squircle
cgCtx.saveGState()
let shadowColor = NSColor.black.withAlphaComponent(0.45).cgColor
cgCtx.setShadow(offset: CGSize(width: 0, height: -24), blur: 36, color: shadowColor)
let shadowPath = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)
NSColor(red: 0.08, green: 0.08, blue: 0.11, alpha: 1.0).setFill()
shadowPath.fill()
cgCtx.restoreGState()

// Clip to squircle for the body
let squirclePath = NSBezierPath(roundedRect: iconRect, xRadius: cornerRadius, yRadius: cornerRadius)
squirclePath.addClip()

// Background: Deep Carbon / Dark Luxury gradient (brandStart -> brandEnd)
let bgStart = NSColor(red: 16/255, green: 17/255, blue: 23/255, alpha: 1.0)
let bgMid   = NSColor(red: 24/255, green: 25/255, blue: 36/255, alpha: 1.0)
let bgEnd   = NSColor(red: 35/255, green: 28/255, blue: 50/255, alpha: 1.0)
let bgGradient = NSGradient(colorsAndLocations: (bgStart, 0.0), (bgMid, 0.5), (bgEnd, 1.0))
bgGradient?.draw(in: iconRect, angle: -45)

// Ambient Neon Glow under the center (Cyan & Violet)
let glowCenter = CGPoint(x: size.width / 2, y: size.height / 2 - 20)
let radialGlow = NSGradient(colorsAndLocations:
    (NSColor(red: 0.0, green: 0.78, blue: 1.0, alpha: 0.28), 0.0),
    (NSColor(red: 0.63, green: 0.42, blue: 1.0, alpha: 0.20), 0.4),
    (NSColor.clear, 1.0)
)
radialGlow?.draw(fromCenter: glowCenter, radius: 10, toCenter: glowCenter, radius: 360, options: [])

// Metallic / Glass hairline edge highlight
let strokePath = NSBezierPath(roundedRect: iconRect.insetBy(dx: 1, dy: 1), xRadius: cornerRadius - 1, yRadius: cornerRadius - 1)
NSColor.white.withAlphaComponent(0.18).setStroke()
strokePath.lineWidth = 2.5
strokePath.stroke()

// DRAW ICON CONTENT: Elegant Sonic Waveform & Liquid Capsule
// Waveform bars with smooth cyan-to-violet gradient
let barCount = 7
let barWidth: CGFloat = 32
let barSpacing: CGFloat = 28
let totalWaveWidth = CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barSpacing
let startX = (size.width - totalWaveWidth) / 2
let centerY = size.height / 2

let heights: [CGFloat] = [90, 190, 310, 420, 310, 190, 90]

let waveGradient = NSGradient(starting:
    NSColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 1.0), // Electric Cyan
    ending: NSColor(red: 0.68, green: 0.45, blue: 1.0, alpha: 1.0) // Neon Violet
)

for i in 0..<barCount {
    let x = startX + CGFloat(i) * (barWidth + barSpacing)
    let h = heights[i]
    let y = centerY - h / 2
    let barRect = NSRect(x: x, y: y, width: barWidth, height: h)
    let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
    
    // Bar subtle bloom/shadow
    cgCtx.saveGState()
    cgCtx.setShadow(offset: .zero, blur: 14, color: NSColor(red: 0.0, green: 0.80, blue: 1.0, alpha: 0.45).cgColor)
    waveGradient?.draw(in: barPath, angle: 90)
    cgCtx.restoreGState()
}

// Center accent: Fluid Voice Mic Dot / Core Glow
let coreDotRadius: CGFloat = 22
let coreRect = NSRect(x: (size.width - coreDotRadius * 2) / 2, y: centerY - coreDotRadius, width: coreDotRadius * 2, height: coreDotRadius * 2)
let corePath = NSBezierPath(ovalIn: coreRect)
NSColor.white.setFill()
corePath.fill()

NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to encode icon PNG")
}

let currentDir = FileManager.default.currentDirectoryPath
let appIconPngPath = "\(currentDir)/scripts/dmg_assets/app_icon.png"
try pngData.write(to: URL(fileURLWithPath: appIconPngPath))
print("Saved 1024x1024 app icon to \(appIconPngPath)")

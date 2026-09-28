import Foundation
import AppKit
import CoreGraphics

let currentDir = FileManager.default.currentDirectoryPath
let bgPath = "\(currentDir)/dmg_background.png"
let previewMockupPath = "\(currentDir)/dmg_preview_mockup.png"
let realDmgWindowPath = "\(currentDir)/assets/real_dmg_window.png"
let githubIconPath = "\(currentDir)/scripts/dmg_assets/github_white.png"
let telegramIconPath = "\(currentDir)/scripts/dmg_assets/telegram_white.png"
let appIconPath = "\(currentDir)/scripts/dmg_assets/app_icon.png"

let bgSize = NSSize(width: 660, height: 480)
let scale: CGFloat = 2.0 // Retina 2x (1320x960)

func createRetinaBitmap(size: NSSize) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width * scale),
        pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = size
    return rep
}

// ----------------------------------------------------
// 1. GENERATE BACKGROUND IMAGE (dmg_background.png)
// ----------------------------------------------------
let bgRep = createRetinaBitmap(size: bgSize)
NSGraphicsContext.saveGraphicsState()
let bgContext = NSGraphicsContext(bitmapImageRep: bgRep)!
NSGraphicsContext.current = bgContext
let cgContext = bgContext.cgContext

// Deep Obsidian Slate base with rich Midnight Violet and Cosmic Cyan ambience
let bgStart = NSColor(red: 13/255, green: 14/255, blue: 22/255, alpha: 1.0)
let bgMid   = NSColor(red: 18/255, green: 17/255, blue: 34/255, alpha: 1.0)
let bgEnd   = NSColor(red: 25/255, green: 20/255, blue: 44/255, alpha: 1.0)
let baseGrad = NSGradient(colorsAndLocations: (bgStart, 0.0), (bgMid, 0.55), (bgEnd, 1.0))
baseGrad?.draw(in: NSRect(origin: .zero, size: bgSize), angle: -45)

// Ambient radial glow top-left (Electric Cyan, smoothly fading to transparent)
let cyanColor = NSColor(red: 0.0, green: 0.80, blue: 1.0, alpha: 0.16)
let cyanTransparent = NSColor(red: 0.0, green: 0.80, blue: 1.0, alpha: 0.0)
let cyanCenter = CGPoint(x: 140, y: bgSize.height - 70)
let cyanGlow = NSGradient(colorsAndLocations:
    (cyanColor, 0.0),
    (cyanColor.withAlphaComponent(0.06), 0.5),
    (cyanTransparent, 1.0)
)
cyanGlow?.draw(fromCenter: cyanCenter, radius: 0, toCenter: cyanCenter, radius: 300, options: [])

// Ambient radial glow bottom-right (Neon Violet, smoothly fading to transparent)
let violetColor = NSColor(red: 0.65, green: 0.35, blue: 1.0, alpha: 0.18)
let violetTransparent = NSColor(red: 0.65, green: 0.35, blue: 1.0, alpha: 0.0)
let violetCenter = CGPoint(x: bgSize.width - 130, y: 90)
let violetGlow = NSGradient(colorsAndLocations:
    (violetColor, 0.0),
    (violetColor.withAlphaComponent(0.07), 0.5),
    (violetTransparent, 1.0)
)
violetGlow?.draw(fromCenter: violetCenter, radius: 0, toCenter: violetCenter, radius: 320, options: [])

// Subtle corner cross marks
func drawCross(at point: NSPoint) {
    let crossPath = NSBezierPath()
    crossPath.move(to: NSPoint(x: point.x - 5, y: point.y))
    crossPath.line(to: NSPoint(x: point.x + 5, y: point.y))
    crossPath.move(to: NSPoint(x: point.x, y: point.y - 5))
    crossPath.line(to: NSPoint(x: point.x, y: point.y + 5))
    crossPath.lineWidth = 1.5
    NSColor.white.withAlphaComponent(0.14).setStroke()
    crossPath.stroke()
}

drawCross(at: NSPoint(x: 30, y: 30))
drawCross(at: NSPoint(x: bgSize.width - 30, y: 30))
drawCross(at: NSPoint(x: 30, y: bgSize.height - 30))
drawCross(at: NSPoint(x: bgSize.width - 30, y: bgSize.height - 30))

// Subtle decorative badges in upper area (placed away from center subtitle)
let badgeAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.18)
]
"⌥ Space".draw(at: NSPoint(x: 65, y: 405), withAttributes: badgeAttrs)
"⚡ Metal GPU".draw(at: NSPoint(x: bgSize.width - 150, y: 405), withAttributes: badgeAttrs)

// Translucent card for drag-and-drop (Frosted Glass container)
let panelRect = NSRect(x: 50, y: 135, width: 560, height: 210)
let panelPath = NSBezierPath(roundedRect: panelRect, xRadius: 18, yRadius: 18)
NSColor.white.withAlphaComponent(0.04).set()
panelPath.fill()
NSColor.white.withAlphaComponent(0.12).set()
panelPath.lineWidth = 1.5
panelPath.stroke()

// Solid elegant chevron arrow (centered at X=330, Y=240)
let arrowPath = NSBezierPath()
let arrowY: CGFloat = 240
let arrowH: CGFloat = 16
let arrowTipW: CGFloat = 24
let arrowBodyW: CGFloat = 36
let arrowStart: CGFloat = 330 - (arrowBodyW + arrowTipW) / 2

arrowPath.move(to: NSPoint(x: arrowStart, y: arrowY - arrowH / 2))
arrowPath.line(to: NSPoint(x: arrowStart + arrowBodyW, y: arrowY - arrowH / 2))
arrowPath.line(to: NSPoint(x: arrowStart + arrowBodyW, y: arrowY - arrowH))
arrowPath.line(to: NSPoint(x: arrowStart + arrowBodyW + arrowTipW, y: arrowY))
arrowPath.line(to: NSPoint(x: arrowStart + arrowBodyW, y: arrowY + arrowH))
arrowPath.line(to: NSPoint(x: arrowStart + arrowBodyW, y: arrowY + arrowH / 2))
arrowPath.line(to: NSPoint(x: arrowStart, y: arrowY + arrowH / 2))
arrowPath.close()

let arrowGrad = NSGradient(starting:
    NSColor(red: 0.0, green: 0.85, blue: 1.0, alpha: 0.70),
    ending: NSColor(red: 0.68, green: 0.45, blue: 1.0, alpha: 0.70)
)
arrowGrad?.draw(in: arrowPath, angle: 0)

// Header: Title "SingAR" & Subtitle
let titleText = "SingAR"
let titleFont = NSFont.systemFont(ofSize: 34, weight: .bold)
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: titleFont,
    .foregroundColor: NSColor.white
]
let titleSize = titleText.size(withAttributes: titleAttrs)
titleText.draw(at: NSPoint(x: (bgSize.width - titleSize.width) / 2, y: bgSize.height - 62), withAttributes: titleAttrs)

let subtitleText = "Перетащите SingAR в Applications для установки"
let subtitleFont = NSFont.systemFont(ofSize: 13, weight: .medium)
let subtitleAttrs: [NSAttributedString.Key: Any] = [
    .font: subtitleFont,
    .foregroundColor: NSColor.white.withAlphaComponent(0.85)
]
let subtitleSize = subtitleText.size(withAttributes: subtitleAttrs)
subtitleText.draw(at: NSPoint(x: (bgSize.width - subtitleSize.width) / 2, y: bgSize.height - 90), withAttributes: subtitleAttrs)

// Bottom links: GitHub & Telegram
let linkFont = NSFont.systemFont(ofSize: 12, weight: .medium)
let linkAttrs: [NSAttributedString.Key: Any] = [
    .font: linkFont,
    .foregroundColor: NSColor.white.withAlphaComponent(0.90)
]
let logoSize = NSSize(width: 18, height: 18)
let bottomY: CGFloat = 64

// GitHub: logo + github.com/zevatov/SingAR
if let ghIcon = NSImage(contentsOfFile: githubIconPath) {
    ghIcon.draw(in: NSRect(x: 50, y: bottomY - 1, width: logoSize.width, height: logoSize.height), from: .zero, operation: .sourceOver, fraction: 0.90)
}
let githubText = "github.com/zevatov/SingAR"
githubText.draw(at: NSPoint(x: 74, y: bottomY), withAttributes: linkAttrs)

// Telegram: logo + t.me/+fgfWiMVNgDdlMTYy
let telegramText = "t.me/+fgfWiMVNgDdlMTYy"
let tgTextSize = telegramText.size(withAttributes: linkAttrs)
let tgRightPadding: CGFloat = 50
let tgTextX = bgSize.width - tgTextSize.width - tgRightPadding
let tgLogoX = tgTextX - 24

if let tgIcon = NSImage(contentsOfFile: telegramIconPath) {
    tgIcon.draw(in: NSRect(x: tgLogoX, y: bottomY - 1, width: logoSize.width, height: logoSize.height), from: .zero, operation: .sourceOver, fraction: 0.90)
}
telegramText.draw(at: NSPoint(x: tgTextX, y: bottomY), withAttributes: linkAttrs)

NSGraphicsContext.restoreGraphicsState()

guard let bgPngData = bgRep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to encode background PNG")
}
try bgPngData.write(to: URL(fileURLWithPath: bgPath))
print("Saved background image to \(bgPath)")

// ----------------------------------------------------
// 2. GENERATE MOCKUP OF OPENED DMG WINDOW (Finder view)
// ----------------------------------------------------
// Adding shadow padding around window for macOS realism
let shadowPadding: CGFloat = 40
let titleBarHeight: CGFloat = 38
let windowContentSize = NSSize(width: bgSize.width, height: bgSize.height + titleBarHeight)
let fullMockupSize = NSSize(width: windowContentSize.width + shadowPadding * 2, height: windowContentSize.height + shadowPadding * 2)

let mockupRep = createRetinaBitmap(size: fullMockupSize)

NSGraphicsContext.saveGraphicsState()
let mockupContext = NSGraphicsContext(bitmapImageRep: mockupRep)!
NSGraphicsContext.current = mockupContext
let mCgCtx = mockupContext.cgContext

let windowRect = NSRect(x: shadowPadding, y: shadowPadding, width: windowContentSize.width, height: windowContentSize.height)

// Draw realistic window drop shadow
mCgCtx.saveGState()
mCgCtx.setShadow(offset: CGSize(width: 0, height: -18), blur: 32, color: NSColor.black.withAlphaComponent(0.55).cgColor)
let shadowPath = NSBezierPath(roundedRect: windowRect, xRadius: 12, yRadius: 12)
NSColor(red: 0.10, green: 0.11, blue: 0.16, alpha: 1.0).setFill()
shadowPath.fill()
mCgCtx.restoreGState()

// Window clip
let windowClip = NSBezierPath(roundedRect: windowRect, xRadius: 12, yRadius: 12)
windowClip.addClip()

// Draw the background image in content area
let bgImg = NSImage(data: bgPngData)!
bgImg.draw(in: NSRect(x: windowRect.origin.x, y: windowRect.origin.y, width: bgSize.width, height: bgSize.height))

// Draw macOS Title Bar
let titleBarRect = NSRect(x: windowRect.origin.x, y: windowRect.origin.y + bgSize.height, width: bgSize.width, height: titleBarHeight)
NSColor(red: 0.12, green: 0.13, blue: 0.18, alpha: 1.0).set()
titleBarRect.fill()

// Title bar traffic lights
let trafficY = windowRect.origin.y + bgSize.height + (titleBarHeight - 12) / 2
let closeDot = NSBezierPath(ovalIn: NSRect(x: windowRect.origin.x + 14, y: trafficY, width: 12, height: 12))
NSColor(red: 1.0, green: 0.36, blue: 0.34, alpha: 1.0).set()
closeDot.fill()

let minDot = NSBezierPath(ovalIn: NSRect(x: windowRect.origin.x + 34, y: trafficY, width: 12, height: 12))
NSColor(red: 1.0, green: 0.74, blue: 0.18, alpha: 1.0).set()
minDot.fill()

let zoomDot = NSBezierPath(ovalIn: NSRect(x: windowRect.origin.x + 54, y: trafficY, width: 12, height: 12))
NSColor(red: 0.16, green: 0.79, blue: 0.29, alpha: 1.0).set()
zoomDot.fill()

// Title bar window icon & title
let miniIconSize: CGFloat = 16
if let appIcon = NSImage(contentsOfFile: appIconPath) {
    let miniIconRect = NSRect(x: windowRect.origin.x + 78, y: trafficY - 2, width: miniIconSize, height: miniIconSize)
    appIcon.draw(in: miniIconRect, from: .zero, operation: .sourceOver, fraction: 1.0)
}
let winTitle = "SingAR"
let winTitleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.85)
]
winTitle.draw(at: NSPoint(x: windowRect.origin.x + 100, y: trafficY - 2), withAttributes: winTitleAttrs)

// Draw Finder items inside window
let iconPixelSize: CGFloat = 110
let labelAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
    .foregroundColor: NSColor.white
]

// Left item: SingAR.app (centered at X = 180 + shadowPadding, Y = 240 + shadowPadding)
let leftX = windowRect.origin.x + 180
let itemY = windowRect.origin.y + 240

if let appIcon = NSImage(contentsOfFile: appIconPath) {
    let appRect = NSRect(x: leftX - iconPixelSize / 2, y: itemY - iconPixelSize / 2 + 10, width: iconPixelSize, height: iconPixelSize)
    appIcon.draw(in: appRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    
    let label = "SingAR.app"
    let lSize = label.size(withAttributes: labelAttrs)
    let labelRect = NSRect(x: leftX - lSize.width / 2 - 6, y: itemY - iconPixelSize / 2 - 12, width: lSize.width + 12, height: lSize.height + 2)
    NSColor.black.withAlphaComponent(0.4).set()
    NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
    label.draw(at: NSPoint(x: leftX - lSize.width / 2, y: itemY - iconPixelSize / 2 - 11), withAttributes: labelAttrs)
}

// Right item: Applications folder
let rightX = windowRect.origin.x + 480
let appsFolderIcon = NSWorkspace.shared.icon(forFile: "/Applications")
let appsRect = NSRect(x: rightX - iconPixelSize / 2, y: itemY - iconPixelSize / 2 + 10, width: iconPixelSize, height: iconPixelSize)
appsFolderIcon.draw(in: appsRect, from: .zero, operation: .sourceOver, fraction: 1.0)

// Symlink badge on folder
let badgeSize: CGFloat = 28
let badgeRect = NSRect(x: rightX - iconPixelSize / 2 - 2, y: itemY - iconPixelSize / 2 + 6, width: badgeSize, height: badgeSize)
let badgeCircle = NSBezierPath(ovalIn: badgeRect)
NSColor(white: 0.95, alpha: 0.95).setFill()
badgeCircle.fill()
NSColor(white: 0.3, alpha: 0.4).setStroke()
badgeCircle.lineWidth = 1.0
badgeCircle.stroke()

// Draw curved shortcut arrow inside badge
let symArrow = NSBezierPath()
let bx = badgeRect.midX
let by = badgeRect.midY
symArrow.move(to: NSPoint(x: bx - 4, y: by - 4))
symArrow.line(to: NSPoint(x: bx + 1, y: by + 1))
symArrow.line(to: NSPoint(x: bx + 5, y: by + 5))
symArrow.lineWidth = 2.0
NSColor.black.setStroke()
symArrow.stroke()

let symHead = NSBezierPath()
symHead.move(to: NSPoint(x: bx + 5, y: by + 5))
symHead.line(to: NSPoint(x: bx + 1, y: by + 5))
symHead.line(to: NSPoint(x: bx + 5, y: by + 1))
symHead.close()
NSColor.black.setFill()
symHead.fill()

let appsLabel = "Applications"
let alSize = appsLabel.size(withAttributes: labelAttrs)
let appsLabelRect = NSRect(x: rightX - alSize.width / 2 - 6, y: itemY - iconPixelSize / 2 - 12, width: alSize.width + 12, height: alSize.height + 2)
NSColor.black.withAlphaComponent(0.4).set()
NSBezierPath(roundedRect: appsLabelRect, xRadius: 4, yRadius: 4).fill()
appsLabel.draw(at: NSPoint(x: rightX - alSize.width / 2, y: itemY - iconPixelSize / 2 - 11), withAttributes: labelAttrs)

NSGraphicsContext.restoreGraphicsState()

guard let mockupPngData = mockupRep.representation(using: .png, properties: [:]) else {
    fatalError("Failed to encode mockup PNG")
}
try mockupPngData.write(to: URL(fileURLWithPath: previewMockupPath))
try mockupPngData.write(to: URL(fileURLWithPath: realDmgWindowPath))
print("Saved preview mockup to \(previewMockupPath) and \(realDmgWindowPath)")

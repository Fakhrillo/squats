// Draws the app icon and writes Support/AppIcon.png (1024 px) and Support/AppIcon.icns.
// Run from the repository root: swift scripts/make-icon.swift
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Everything is drawn on a 1024-point canvas with y pointing up, then scaled.
func drawIcon(in ctx: CGContext) {
    let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
    func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // The standard macOS icon body: an 824-point continuous-corner square with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = RoundedRectangle(cornerRadius: 185, style: .continuous).path(in: body).cgPath

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.30))
    ctx.addPath(shape)
    ctx.setFillColor(rgb(0xF2643A))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Warm sunrise: amber at the top, coral red at the bottom.
    let sunrise = CGGradient(colorsSpace: space, colors: [rgb(0xFFB454), rgb(0xF9773D), rgb(0xE8452F)] as CFArray,
                             locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(sunrise, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // A soft light from the upper left.
    let glow = CGGradient(colorsSpace: space, colors: [rgb(0xFFFFFF, 0.14), rgb(0xFFFFFF, 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 300, y: 860), startRadius: 0,
                           endCenter: CGPoint(x: 300, y: 860), endRadius: 620, options: [])

    // The rep counter: a faint full ring, most of it already filled in.
    let center = CGPoint(x: 512, y: 512)
    ctx.setLineCap(.round)
    ctx.setLineWidth(34)
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.18))
    ctx.addArc(center: center, radius: 318, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.72))
    ctx.addArc(center: center, radius: 318, startAngle: .pi / 2, endAngle: .pi / 2 - 1.42 * .pi, clockwise: true)
    ctx.strokePath()

    // The figure at the bottom of a squat, side on: thighs level, back straight, arms forward.
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0x8A1F0C, 0.35))
    ctx.setStrokeColor(white)
    ctx.setFillColor(white)
    ctx.setLineWidth(62)
    ctx.setLineJoin(.round)

    ctx.beginTransparencyLayer(auxiliaryInfo: nil)   // one shadow for the whole figure
    ctx.move(to: CGPoint(x: 560, y: 316))            // toe
    ctx.addLine(to: CGPoint(x: 444, y: 316))         // heel
    ctx.addLine(to: CGPoint(x: 552, y: 448))         // knee
    ctx.addLine(to: CGPoint(x: 370, y: 454))         // hip
    ctx.addLine(to: CGPoint(x: 466, y: 628))         // shoulder
    ctx.strokePath()
    ctx.move(to: CGPoint(x: 466, y: 628))            // arm, reaching forward for balance
    ctx.addLine(to: CGPoint(x: 660, y: 606))
    ctx.strokePath()
    ctx.fillEllipse(in: CGRect(x: 510 - 52, y: 718 - 52, width: 104, height: 104))   // head
    ctx.endTransparencyLayer()

    ctx.restoreGState()
}

func render(_ pixels: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "could not write \(url.path)")
}

let support = URL(fileURLWithPath: "Support", isDirectory: true)
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    writePNG(render(points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(render(points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
writePNG(render(1024), to: support.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", support.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
print("wrote Support/AppIcon.png and Support/AppIcon.icns")

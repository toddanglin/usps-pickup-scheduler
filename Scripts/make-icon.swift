#!/usr/bin/env swift
//
//  make-icon.swift
//  Pickup
//
//  Standalone, dependency-free app icon generator.
//
//  Usage:
//      swift Scripts/make-icon.swift <path-to-AppIcon.appiconset>
//
//  Renders a 1024x1024 master icon (macOS Big Sur style squircle + envelope
//  glyph) using AppKit/CoreGraphics, then exports the ten standard macOS PNG
//  sizes plus a matching Contents.json into the given .appiconset directory.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Design constants

/// Master canvas is always 1024x1024 (the @2x of the 512pt slot).
let canvas: CGFloat = 1024

/// macOS Big Sur icon grid: the body occupies 824x824 of the 1024 canvas,
/// leaving a 100pt transparent margin on every side.
let bodyInset: CGFloat = 100
let bodySide: CGFloat = canvas - bodyInset * 2   // 824

/// Superellipse exponent. n == 5 closely approximates Apple's continuous
/// ("squircle") corners; larger is boxier, smaller is rounder.
/// The equivalent visual corner radius here is ~185pt.
let squircleExponent: CGFloat = 5.8

// Gradient stops.
let topBlue    = (r: 0x4A / 255.0, g: 0x9D / 255.0, b: 0xFF / 255.0)  // #4A9DFF
let bottomBlue = (r: 0x0B / 255.0, g: 0x5E / 255.0, b: 0xD7 / 255.0)  // #0B5ED7

// MARK: - Geometry helpers

/// Continuous-corner "squircle" path: a superellipse
/// |x/a|^n + |y/b|^n = 1 sampled densely and closed.
///
/// Unlike a plain rounded rect this has no curvature discontinuity where the
/// arc meets the straight edge, which is what gives Apple's icons their look.
func squirclePath(center: CGPoint, halfWidth a: CGFloat, halfHeight b: CGFloat,
                  exponent n: CGFloat, samples: Int = 1024) -> CGPath {
    let path = CGMutablePath()
    let e = 2.0 / n
    for i in 0..<samples {
        let t = (CGFloat(i) / CGFloat(samples)) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = center.x + a * (ct < 0 ? -1 : 1) * pow(abs(ct), e)
        let y = center.y + b * (st < 0 ? -1 : 1) * pow(abs(st), e)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
        else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Rounded rectangle path (used for the envelope body).
func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func makeGradient(_ stops: [(color: (r: Double, g: Double, b: Double), alpha: Double, location: CGFloat)]) -> CGGradient {
    let space = CGColorSpaceCreateDeviceRGB()
    var comps: [CGFloat] = []
    var locs: [CGFloat] = []
    for s in stops {
        comps.append(contentsOf: [CGFloat(s.color.r), CGFloat(s.color.g), CGFloat(s.color.b), CGFloat(s.alpha)])
        locs.append(s.location)
    }
    return CGGradient(colorSpace: space, colorComponents: comps, locations: locs, count: stops.count)!
}

// MARK: - Master render

func renderMaster() -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil,
                              width: Int(canvas), height: Int(canvas),
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("Unable to create bitmap context")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    let half = bodySide / 2
    let body = squirclePath(center: center, halfWidth: half, halfHeight: half, exponent: squircleExponent)
    let bodyRect = CGRect(x: bodyInset, y: bodyInset, width: bodySide, height: bodySide)

    // --- Body: vertical blue gradient (top light -> bottom deep) -----------
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let bodyGradient = makeGradient([
        (bottomBlue, 1.0, 0.0),   // location 0 == bottom of the body (y-up)
        (topBlue,    1.0, 1.0),
    ])
    ctx.drawLinearGradient(bodyGradient,
                           start: CGPoint(x: 0, y: bodyRect.minY),
                           end:   CGPoint(x: 0, y: bodyRect.maxY),
                           options: [])

    // Subtle top-edge inner highlight: white 18% fading out over the top ~15%.
    let highlight = makeGradient([
        ((1, 1, 1), 0.0,  0.0),
        ((1, 1, 1), 0.18, 1.0),
    ])
    ctx.drawLinearGradient(highlight,
                           start: CGPoint(x: 0, y: bodyRect.maxY - bodySide * 0.15),
                           end:   CGPoint(x: 0, y: bodyRect.maxY),
                           options: [])

    // Faint bottom-edge darkening so the body reads as slightly convex.
    let shade = makeGradient([
        ((0, 0, 0), 0.14, 0.0),
        ((0, 0, 0), 0.0,  1.0),
    ])
    ctx.drawLinearGradient(shade,
                           start: CGPoint(x: 0, y: bodyRect.minY),
                           end:   CGPoint(x: 0, y: bodyRect.minY + bodySide * 0.16),
                           options: [])
    ctx.restoreGState()

    // Hairline inner rim for crispness at large sizes.
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.addPath(body)
    ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.22)
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    // --- Glyph: white envelope --------------------------------------------
    let envW = bodySide * 0.60                       // ~60% of the body width
    let envH = envW * 0.68                           // classic #10 envelope-ish
    let envRect = CGRect(x: center.x - envW / 2,
                         y: center.y - envH / 2,
                         width: envW, height: envH)
    let envRadius = envW * 0.055
    let envelope = roundedRectPath(envRect, radius: envRadius)

    // Drop shadow applied once to the whole glyph via a transparency layer.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    // Envelope body.
    ctx.addPath(envelope)
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fillPath()

    // Flap "V": a closed shape from the top corners down to the fold point,
    // tinted with a translucent body-blue so it reads as a crease rather than
    // a hole. Clipped to the envelope so it inherits the rounded top corners.
    let foldDepth = envH * 0.56
    let inset = envRadius * 0.55
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: envRect.minX + inset, y: envRect.maxY - inset * 0.4))
    flap.addLine(to: CGPoint(x: center.x, y: envRect.maxY - foldDepth))
    flap.addLine(to: CGPoint(x: envRect.maxX - inset, y: envRect.maxY - inset * 0.4))
    flap.addLine(to: CGPoint(x: envRect.maxX, y: envRect.maxY))
    flap.addLine(to: CGPoint(x: envRect.minX, y: envRect.maxY))
    flap.closeSubpath()

    ctx.saveGState()
    ctx.addPath(envelope)
    ctx.clip()
    ctx.addPath(flap)
    ctx.setFillColor(red: CGFloat(topBlue.r), green: CGFloat(topBlue.g), blue: CGFloat(topBlue.b), alpha: 0.22)
    ctx.fillPath()

    // Crisp fold line along the V.
    let vLine = CGMutablePath()
    vLine.move(to: CGPoint(x: envRect.minX + inset, y: envRect.maxY - inset * 0.4))
    vLine.addLine(to: CGPoint(x: center.x, y: envRect.maxY - foldDepth))
    vLine.addLine(to: CGPoint(x: envRect.maxX - inset, y: envRect.maxY - inset * 0.4))
    ctx.addPath(vLine)
    ctx.setStrokeColor(red: CGFloat(bottomBlue.r), green: CGFloat(bottomBlue.g), blue: CGFloat(bottomBlue.b), alpha: 0.45)
    ctx.setLineWidth(envW * 0.028)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.endTransparencyLayer()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { fatalError("Unable to render master image") }
    return image
}

// MARK: - Export

struct Slot {
    let filename: String
    let size: String   // e.g. "16x16"
    let scale: String  // e.g. "2x"
    let pixels: Int
}

let slots: [Slot] = [
    Slot(filename: "icon_16x16.png",      size: "16x16",   scale: "1x", pixels: 16),
    Slot(filename: "icon_16x16@2x.png",   size: "16x16",   scale: "2x", pixels: 32),
    Slot(filename: "icon_32x32.png",      size: "32x32",   scale: "1x", pixels: 32),
    Slot(filename: "icon_32x32@2x.png",   size: "32x32",   scale: "2x", pixels: 64),
    Slot(filename: "icon_128x128.png",    size: "128x128", scale: "1x", pixels: 128),
    Slot(filename: "icon_128x128@2x.png", size: "128x128", scale: "2x", pixels: 256),
    Slot(filename: "icon_256x256.png",    size: "256x256", scale: "1x", pixels: 256),
    Slot(filename: "icon_256x256@2x.png", size: "256x256", scale: "2x", pixels: 512),
    Slot(filename: "icon_512x512.png",    size: "512x512", scale: "1x", pixels: 512),
    Slot(filename: "icon_512x512@2x.png", size: "512x512", scale: "2x", pixels: 1024),
]

func writePNG(master: CGImage, pixels: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        fatalError("Unable to create bitmap rep for \(pixels)px")
    }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Unable to create graphics context for \(pixels)px")
    }
    NSGraphicsContext.current = gctx
    gctx.imageInterpolation = .high
    gctx.cgContext.interpolationQuality = .high
    gctx.cgContext.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
    gctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode PNG for \(pixels)px")
    }
    try data.write(to: url)
}

func contentsJSON() -> String {
    var images: [String] = []
    for s in slots {
        images.append("""
            {
              "filename" : "\(s.filename)",
              "idiom" : "mac",
              "scale" : "\(s.scale)",
              "size" : "\(s.size)"
            }
        """)
    }
    return """
    {
      "images" : [
    \(images.joined(separator: ",\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: swift Scripts/make-icon.swift <path-to-AppIcon.appiconset>\n".data(using: .utf8)!)
    exit(1)
}

let outDir = URL(fileURLWithPath: args[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let master = renderMaster()
for slot in slots {
    let url = outDir.appendingPathComponent(slot.filename)
    do {
        try writePNG(master: master, pixels: slot.pixels, to: url)
        print("wrote \(slot.filename) (\(slot.pixels)x\(slot.pixels))")
    } catch {
        FileHandle.standardError.write("failed to write \(slot.filename): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

let contentsURL = outDir.appendingPathComponent("Contents.json")
try contentsJSON().write(to: contentsURL, atomically: true, encoding: .utf8)
print("wrote Contents.json")
print("icon set written to \(outDir.path)")

import AppKit

// Zephyr's app icon: a bold rounded Z, centered on a blue gradient squircle
// (Apple icon grid: 824pt squircle on a 1024pt canvas). This script is the
// icon's source of truth — regenerate the icon set with:
//
//     swift Design/AppIconGenerator.swift Zephyr/Assets.xcassets/AppIcon.appiconset
//
// after editing, then rebuild.

let canvas: CGFloat = 1024
let margin: CGFloat = 100
let corner: CGFloat = 824 * 0.2237

func draw(into ctx: CGContext) {
    let squircle = CGPath(
        roundedRect: CGRect(x: margin, y: margin, width: 824, height: 824),
        cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Squircle with soft shadow.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -14), blur: 36,
        color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(red: 0.16, green: 0.55, blue: 0.94, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let colors = [
        CGColor(red: 0.16, green: 0.55, blue: 0.94, alpha: 1),
        CGColor(red: 0.05, green: 0.16, blue: 0.45, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient, start: CGPoint(x: canvas / 2, y: margin),
        end: CGPoint(x: canvas / 2, y: canvas - margin), options: [])
    ctx.restoreGState()

    // The Z: bold, plain, centered.
    let z = CGMutablePath()
    z.move(to: CGPoint(x: 332, y: 316))
    z.addLine(to: CGPoint(x: 692, y: 316))
    z.addLine(to: CGPoint(x: 332, y: 708))
    z.addLine(to: CGPoint(x: 692, y: 708))

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -10), blur: 26,
        color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(z)
    ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
    ctx.setLineWidth(128)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

func render(pixels: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    ctx.translateBy(x: 0, y: canvas)
    ctx.scaleBy(x: 1, y: -1)
    draw(into: ctx)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.lastPathComponent) (\(pixels)px)")
}

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : ".")

let specs: [(pixels: Int, filename: String)] = [
    (16, "icon_16.png"), (32, "icon_16@2x.png"),
    (32, "icon_32.png"), (64, "icon_32@2x.png"),
    (128, "icon_128.png"), (256, "icon_128@2x.png"),
    (256, "icon_256.png"), (512, "icon_256@2x.png"),
    (512, "icon_512.png"), (1024, "icon_512@2x.png"),
]
for spec in specs {
    render(pixels: spec.pixels, to: outputDir.appendingPathComponent(spec.filename))
}

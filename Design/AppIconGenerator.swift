import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Zephyr's app icon: a bold rounded Z on a blue gradient. This script is the
// icon's source of truth. After editing, regenerate from the repository root
// and rebuild:
//
//     swift Design/AppIconGenerator.swift
//
// It writes the icon in the form each platform takes:
//
//   macOS, iOS   Zephyr/AppIcon.icon, an Icon Composer bundle: icon.json plus
//                one SVG per layer. The asset compiler renders every size from
//                it and applies the system shape and the glass, dark, clear
//                and tinted treatments.
//   visionOS     Zephyr/Assets.xcassets/AppIcon.solidimagestack: three 1024 px
//                layers. It shares the name AppIcon with the bundle; each
//                platform's build takes its own.
//   tvOS         Apps/TV/Assets.xcassets/App Icon & Top Shelf Image.brandassets:
//                the layered icon at its two sizes, and the Top Shelf images.
//
// Everywhere the artwork is full bleed and has no plate, mask or shadow of its
// own: each system crops, lights and shadows the layers itself.
//
// The Z is three round-capped strokes on two layers. The two bars sit in
// front of the diagonal, which is a shade darker, so there is an edge to
// catch where they cross.
//
// To look at the Icon Composer result without building:
//
//     "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
//         Zephyr/AppIcon.icon --export-image --output-file icon.png \
//         --platform macOS --rendition Default --width 512 --height 512 --scale 2
//
// Renditions: Default, Dark, TintedLight, TintedDark, ClearLight, ClearDark.

// MARK: Geometry, on the 1024 x 1024 canvas with y downward

let canvas = 1024
/// The centre lines of the Z and the width of its strokes.
let left = 298, right = 726, top = 280, bottom = 744
let weight = 152

/// How large the Z is drawn elsewhere, relative to the Icon Composer icon,
/// with the image's shorter side standing for that icon's canvas. visionOS
/// crops to a circle, so the Z is drawn smaller to stay clear of it.
let visionFit = 0.86
let tvFit = 1.0
let topShelfFit = 0.8

// MARK: Colours

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

struct Color {
    let red, green, blue: Double

    init(_ red: Double, _ green: Double, _ blue: Double) {
        (self.red, self.green, self.blue) = (red, green, blue)
    }

    var iconComposer: String {
        String(format: "extended-srgb:%.5f,%.5f,%.5f,1.00000", red, green, blue)
    }
    var hex: String {
        String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }
    var cgColor: CGColor {
        CGColor(colorSpace: sRGB, components: [red, green, blue, 1])!
    }
}

/// The ground, top to bottom.
let ground = [Color(0.16, 0.55, 0.94), Color(0.05, 0.16, 0.45)]
let barColor = Color(1, 1, 1)
let diagonalColor = Color(219 / 255, 232 / 255, 1)
/// In Dark, macOS and iOS swap the ground for charcoal and would paint the
/// white strokes with the ground's gradient, which ends too dark to see
/// against it. These brighter blues replace it.
let barDark = [Color(0.36, 0.72, 1.00), Color(0.14, 0.50, 0.96)]
let diagonalDark = [Color(0.16, 0.50, 0.92), Color(0.09, 0.36, 0.80)]

// MARK: Layers, front to back

struct Layer {
    let name: String
    /// Each stroke runs from one point to another.
    let strokes: [(from: (Int, Int), to: (Int, Int))]
    let color: Color
    let dark: [Color]
}

let bars = Layer(
    name: "Bars",
    strokes: [((left, top), (right, top)), ((left, bottom), (right, bottom))],
    color: barColor, dark: barDark)
let diagonal = Layer(
    name: "Diagonal",
    strokes: [((right, top), (left, bottom))],
    color: diagonalColor, dark: diagonalDark)

// MARK: Writing files

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let files = FileManager.default

func writeJSON(_ object: [String: Any], to url: URL) throws {
    var json = try JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    json.append(contentsOf: "\n".utf8)
    try json.write(to: url)
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

// MARK: macOS and iOS: the Icon Composer bundle

func svg(_ layer: Layer) -> String {
    let path = layer.strokes
        .map { "M\($0.from.0) \($0.from.1)L\($0.to.0) \($0.to.1)" }
        .joined()
    return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(canvas)" height="\(canvas)" viewBox="0 0 \(canvas) \(canvas)">
          <path d="\(path)" fill="none" stroke="\(layer.color.hex)" stroke-width="\(weight)" stroke-linecap="round"/>
        </svg>

        """
}

/// One glass group per layer, each with the system's neutral shadow.
func group(_ layer: Layer) -> [String: Any] {
    [
        "layers": [[
            "fill-specializations": [[
                "appearance": "dark",
                "value": ["linear-gradient": layer.dark.map(\.iconComposer)],
            ]],
            "image-name": "\(layer.name).svg",
            "name": layer.name,
        ]],
        "shadow": ["kind": "neutral", "opacity": 0.5],
        "translucency": ["enabled": false, "value": 0.5],
    ]
}

func writeIconComposerBundle() throws {
    let bundle = root.appendingPathComponent("Zephyr/AppIcon.icon")
    let assets = bundle.appendingPathComponent("Assets")
    try files.createDirectory(at: assets, withIntermediateDirectories: true)
    for layer in [bars, diagonal] {
        try svg(layer).write(
            to: assets.appendingPathComponent("\(layer.name).svg"),
            atomically: true, encoding: .utf8)
    }
    try writeJSON(
        [
            "fill": ["linear-gradient": ground.map(\.iconComposer)],
            "groups": [bars, diagonal].map(group),
            "supported-platforms": ["squares": "shared"],
        ],
        to: bundle.appendingPathComponent("icon.json"))
}

// MARK: visionOS and tvOS: bitmap layers in an asset catalog

/// Draws the ground, some layers of the Z, or both, with the Z centred.
/// An image with the ground has no alpha channel.
func raster(width: Int, height: Int, fit: Double, ground hasGround: Bool, layers: [Layer]) -> CGImage {
    let alpha: CGImageAlphaInfo = hasGround ? .noneSkipLast : .premultipliedLast
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: sRGB, bitmapInfo: alpha.rawValue)!
    // y downward, like the SVG layers.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    if hasGround {
        let gradient = CGGradient(
            colorsSpace: sRGB, colors: ground.map(\.cgColor) as CFArray, locations: [0, 1])!
        context.drawLinearGradient(
            gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
    }
    let scale = CGFloat(min(width, height)) / CGFloat(canvas) * fit
    context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -CGFloat(canvas) / 2, y: -CGFloat(canvas) / 2)
    context.setLineWidth(CGFloat(weight))
    context.setLineCap(.round)
    for layer in layers.reversed() {
        for stroke in layer.strokes {
            context.move(to: CGPoint(x: stroke.from.0, y: stroke.from.1))
            context.addLine(to: CGPoint(x: stroke.to.0, y: stroke.to.1))
        }
        context.setStrokeColor(layer.color.cgColor)
        context.strokePath()
    }
    return context.makeImage()!
}

let catalogInfo: [String: Any] = ["author": "xcode", "version": 1]

/// An image set with one drawing at each scale; `draw` gets the scale.
func writeImageSet(
    at url: URL, name: String, idiom: String, scales: [Int], draw: (Int) -> CGImage
) throws {
    try files.createDirectory(at: url, withIntermediateDirectories: true)
    var images: [[String: Any]] = []
    for scale in scales {
        let filename = scale == 1 ? "\(name).png" : "\(name)@\(scale)x.png"
        try writePNG(draw(scale), to: url.appendingPathComponent(filename))
        images.append(["filename": filename, "idiom": idiom, "scale": "\(scale)x"])
    }
    try writeJSON(
        ["images": images, "info": catalogInfo], to: url.appendingPathComponent("Contents.json"))
}

/// A three-layer image: the bars, the diagonal, and the opaque ground.
/// `kind` is "imagestack" on tvOS and "solidimagestack" on visionOS.
func writeStack(
    at url: URL, kind: String, idiom: String, width: Int, height: Int, scales: [Int], fit: Double
) throws {
    let parts: [(name: String, ground: Bool, layers: [Layer])] = [
        ("Front", false, [bars]), ("Middle", false, [diagonal]), ("Back", true, []),
    ]
    for part in parts {
        let folder = url.appendingPathComponent("\(part.name).\(kind)layer")
        try writeImageSet(
            at: folder.appendingPathComponent("Content.imageset"),
            name: part.name, idiom: idiom, scales: scales
        ) { scale in
            raster(
                width: width * scale, height: height * scale, fit: fit,
                ground: part.ground, layers: part.layers)
        }
        try writeJSON(["info": catalogInfo], to: folder.appendingPathComponent("Contents.json"))
    }
    try writeJSON(
        [
            "info": catalogInfo,
            "layers": parts.map { ["filename": "\($0.name).\(kind)layer"] },
        ],
        to: url.appendingPathComponent("Contents.json"))
}

func writeVisionStack() throws {
    // One 1024 px image per layer, declared as 512 pt at 2x.
    try writeStack(
        at: root.appendingPathComponent("Zephyr/Assets.xcassets/AppIcon.solidimagestack"),
        kind: "solidimagestack", idiom: "vision", width: 512, height: 512, scales: [2],
        fit: visionFit)
}

func writeTVBrandAssets() throws {
    let catalog = root.appendingPathComponent("Apps/TV/Assets.xcassets")
    let brand = catalog.appendingPathComponent("App Icon & Top Shelf Image.brandassets")
    // (name, role, width, height, scales, layered)
    let assets: [(name: String, role: String, width: Int, height: Int, scales: [Int], layered: Bool)] = [
        ("App Icon - App Store", "primary-app-icon", 1280, 768, [1], true),
        ("App Icon", "primary-app-icon", 400, 240, [1, 2], true),
        ("Top Shelf Image Wide", "top-shelf-image-wide", 2320, 720, [1, 2], false),
        ("Top Shelf Image", "top-shelf-image", 1920, 720, [1, 2], false),
    ]
    for asset in assets {
        if asset.layered {
            try writeStack(
                at: brand.appendingPathComponent("\(asset.name).imagestack"),
                kind: "imagestack", idiom: "tv", width: asset.width, height: asset.height,
                scales: asset.scales, fit: tvFit)
        } else {
            // The Top Shelf images are flat: the whole icon on a wide ground.
            try writeImageSet(
                at: brand.appendingPathComponent("\(asset.name).imageset"),
                name: asset.name, idiom: "tv", scales: asset.scales
            ) { scale in
                raster(
                    width: asset.width * scale, height: asset.height * scale, fit: topShelfFit,
                    ground: true, layers: [bars, diagonal])
            }
        }
    }
    try writeJSON(
        [
            "assets": assets.map {
                [
                    "filename": "\($0.name).\($0.layered ? "imagestack" : "imageset")",
                    "idiom": "tv",
                    "role": $0.role,
                    "size": "\($0.width)x\($0.height)",
                ]
            },
            "info": catalogInfo,
        ],
        to: brand.appendingPathComponent("Contents.json"))
    try writeJSON(["info": catalogInfo], to: catalog.appendingPathComponent("Contents.json"))
}

try writeIconComposerBundle()
print("wrote Zephyr/AppIcon.icon")
try writeVisionStack()
print("wrote Zephyr/Assets.xcassets/AppIcon.solidimagestack")
try writeTVBrandAssets()
print("wrote Apps/TV/Assets.xcassets")

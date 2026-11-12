import Foundation

// Zephyr's app icon: a bold rounded Z on a blue gradient, written as an Icon
// Composer bundle. This script is the icon's source of truth. After editing,
// regenerate the bundle from the repository root and rebuild:
//
//     swift Design/AppIconGenerator.swift
//
// The output is Zephyr/AppIcon.icon: icon.json plus one SVG per layer. The
// asset compiler renders every size macOS and iOS need from it and applies
// the system shape and the glass, dark, clear and tinted treatments, so the
// artwork is full bleed and has no plate, mask or shadow of its own.
//
// The Z is three round-capped strokes on two layers. The two bars sit in
// front of the diagonal, which is a shade darker, so the glass has an edge to
// catch where they cross.
//
// To look at the result without building:
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

// MARK: Colours

func color(_ red: Double, _ green: Double, _ blue: Double) -> String {
    String(format: "extended-srgb:%.5f,%.5f,%.5f,1.00000", red, green, blue)
}

/// The ground, top to bottom.
let ground = [color(0.16, 0.55, 0.94), color(0.05, 0.16, 0.45)]
let barColor = "#FFFFFF"
let diagonalColor = "#DBE8FF"
/// In Dark the system swaps the ground for charcoal and would paint the white
/// strokes with the ground's gradient, which ends too dark to see against it.
/// These brighter blues replace it.
let barDark = [color(0.36, 0.72, 1.00), color(0.14, 0.50, 0.96)]
let diagonalDark = [color(0.16, 0.50, 0.92), color(0.09, 0.36, 0.80)]

// MARK: Layers, front to back

struct Layer {
    let name: String
    /// Each stroke runs from one point to another.
    let strokes: [(from: (Int, Int), to: (Int, Int))]
    let color: String
    let dark: [String]
}

let layers = [
    Layer(
        name: "Bars",
        strokes: [((left, top), (right, top)), ((left, bottom), (right, bottom))],
        color: barColor, dark: barDark),
    Layer(
        name: "Diagonal",
        strokes: [((right, top), (left, bottom))],
        color: diagonalColor, dark: diagonalDark),
]

func svg(_ layer: Layer) -> String {
    let path = layer.strokes
        .map { "M\($0.from.0) \($0.from.1)L\($0.to.0) \($0.to.1)" }
        .joined()
    return """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(canvas)" height="\(canvas)" viewBox="0 0 \(canvas) \(canvas)">
          <path d="\(path)" fill="none" stroke="\(layer.color)" stroke-width="\(weight)" stroke-linecap="round"/>
        </svg>

        """
}

/// One glass group per layer, each with the system's neutral shadow.
func group(_ layer: Layer) -> [String: Any] {
    [
        "layers": [[
            "fill-specializations": [
                ["appearance": "dark", "value": ["linear-gradient": layer.dark]]
            ],
            "image-name": "\(layer.name).svg",
            "name": layer.name,
        ]],
        "shadow": ["kind": "neutral", "opacity": 0.5],
        "translucency": ["enabled": false, "value": 0.5],
    ]
}

// MARK: Output

let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
let bundle = root.appendingPathComponent("Zephyr/AppIcon.icon")
let assets = bundle.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

for layer in layers {
    try svg(layer).write(
        to: assets.appendingPathComponent("\(layer.name).svg"),
        atomically: true, encoding: .utf8)
}

let document: [String: Any] = [
    "fill": ["linear-gradient": ground],
    "groups": layers.map(group),
    "supported-platforms": ["squares": "shared"],
]
var json = try JSONSerialization.data(
    withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
json.append(contentsOf: "\n".utf8)
try json.write(to: bundle.appendingPathComponent("icon.json"))
print("wrote Zephyr/AppIcon.icon")

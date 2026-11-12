#!/usr/bin/env swift
// Renders the app icon (a tray of messages on a blue rounded square) into the asset catalog.
// Usage: swift scripts/make-icon.swift
import AppKit

let outDir = "Swiftbus/Assets.xcassets/AppIcon.appiconset"
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func render(px: Int) -> Data {
    let s = CGFloat(px)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        // macOS icon grid: artwork inset ~10% with a continuous-corner rounded square.
        let body = rect.insetBy(dx: s * 0.1, dy: s * 0.1)
        let shape = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
        NSGradient(colors: [NSColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 1),
                            NSColor(red: 0.08, green: 0.20, blue: 0.55, alpha: 1)])!.draw(in: shape, angle: -90)

        let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                   width: size.width, height: size.height))
        }

        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    rep.size = NSSize(width: px, height: px)
    return rep.representation(using: .png, properties: [:])!
}

for (name, px) in sizes {
    try render(px: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}

var images: [[String: String]] = []
for (name, px) in sizes {
    let scale = name.hasSuffix("@2x") ? "2x" : "1x"
    let points = scale == "2x" ? px / 2 : px
    images.append(["filename": "\(name).png", "idiom": "mac", "scale": scale, "size": "\(points)x\(points)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(outDir)/Contents.json"))
print("Wrote \(sizes.count) icons")

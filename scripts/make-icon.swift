#!/usr/bin/env swift
// Renders the app icon (a tray of messages with a red dead-letter badge) into the asset catalog.
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
            symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2 - s * 0.02,
                                   width: size.width, height: size.height))
        }

        // Red badge: the dead-letter count.
        let d = s * 0.26
        let badge = NSRect(x: body.maxX - d * 0.95, y: body.maxY - d * 0.95, width: d, height: d)
        NSColor(red: 0.95, green: 0.2, blue: 0.2, alpha: 1).setFill()
        NSBezierPath(ovalIn: badge).fill()
        NSColor.white.setStroke()
        let ring = NSBezierPath(ovalIn: badge.insetBy(dx: d * 0.04, dy: d * 0.04))
        ring.lineWidth = d * 0.08
        ring.stroke()
        let mark = NSAttributedString(string: "!", attributes: [
            .font: NSFont.systemFont(ofSize: d * 0.62, weight: .heavy), .foregroundColor: NSColor.white])
        let ms = mark.size()
        mark.draw(at: NSPoint(x: badge.midX - ms.width / 2, y: badge.midY - ms.height / 2))
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

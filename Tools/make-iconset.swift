// Compose a macOS .iconset from a full-bleed artwork PNG.
// macOS app icons need transparent padding around a rounded-rect artwork
// (Apple grid: 1024 canvas, 824 art, ~185 corner radius); a full-bleed square
// makes the Dock and notification banners render a white-cornered blob.
//
// usage: swift Tools/make-iconset.swift <artwork.png> <out.iconset>
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: make-iconset <artwork.png> <out.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// (pixel size, iconset file name)
let specs: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    (1024, "icon_1024x1024.png"),
]

for (px, name) in specs {
    let side = CGFloat(px)
    let inset = side * 0.10
    let art = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let radius = art.width * 0.225

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
    else { continue }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    cg.clear(CGRect(x: 0, y: 0, width: side, height: side))
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: art, cornerWidth: radius, cornerHeight: radius, transform: nil))
    cg.clip()
    src.draw(in: art, from: .zero, operation: .copy, fraction: 1)
    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: outDir.appendingPathComponent(name))
}
print("wrote \(specs.count) representations to \(outDir.path)")

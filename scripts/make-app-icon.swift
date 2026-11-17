import AppKit
// Usage: swift scripts/make-app-icon.swift scripts/app-icon-source.png Bookkeeper/Assets.xcassets/AppIcon.appiconset
// macOS app icon grid: an 824-pt rounded square centred on a 1024 canvas, the artwork
// filling it — what macOS 26 shows as-is instead of setting the icon on a grey plate.
let src = NSImage(contentsOfFile: CommandLine.arguments[1])!
let outDir = CommandLine.arguments[2]
func render(_ px: Int) -> Data {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  rep.size = NSSize(width: px, height: px)
  NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current!.imageInterpolation = .high
  let k = CGFloat(px) / 1024
  let tile = NSRect(x: 100*k, y: 100*k, width: 824*k, height: 824*k)
  let shape = NSBezierPath(roundedRect: tile, xRadius: 185*k, yRadius: 185*k)
  // The fill is the circle's own green as drawn here, read back from the pixels, so the
  // circle's edge disappears into it.
  let art0: CGFloat = 900*k
  src.draw(in: NSRect(x: (CGFloat(px)-art0)/2, y: (CGFloat(px)-art0)/2, width: art0, height: art0))
  let fill = rep.colorAt(x: Int((CGFloat(px)-art0)/2 + art0*0.08), y: px/2)!
  NSColor.clear.set(); NSRect(x: 0, y: 0, width: px, height: px).fill(using: .copy)
  fill.setFill(); shape.fill()
  shape.addClip()
  // The old round icon, its circle the same green as the tile, so only the tree shows
  // — a little smaller than the circle had it, for air round the tree in the square.
  let art: CGFloat = 760*k
  src.draw(in: NSRect(x: (CGFloat(px)-art)/2, y: (CGFloat(px)-art)/2, width: art, height: art))
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}
for px in [16, 32, 64, 128, 256, 512, 1024] {
  try! render(px).write(to: URL(fileURLWithPath: "\(outDir)/icon_\(px).png"))
}

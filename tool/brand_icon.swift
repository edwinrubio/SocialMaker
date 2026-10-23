// Draws the SocialMaker brand marks with Core Graphics (no design tools needed).
//
//   swift tool/brand_icon.swift assets/brand
//
// Writes icon.png (full app icon, opaque), foreground.png (Android adaptive
// foreground, transparent), monochrome.png (Android themed icon) and
// logo.png and splash_android12.png (splash marks, transparent), all
// 1024×1024.
import AppKit
import CoreGraphics

let size: CGFloat = 1024
let pink = CGColor(srgbRed: 0xFE / 255, green: 0x2C / 255, blue: 0x55 / 255, alpha: 1)
let orange = CGColor(srgbRed: 0xFF / 255, green: 0x8A / 255, blue: 0x3D / 255, alpha: 1)
let plumTop = CGColor(srgbRed: 0x2B / 255, green: 0x0D / 255, blue: 0x22 / 255, alpha: 1)
let plumBottom = CGColor(srgbRed: 0x0C / 255, green: 0x09 / 255, blue: 0x12 / 255, alpha: 1)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func gradient(_ colors: [CGColor]) -> CGGradient {
  CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}

/// The mark: a ring cut into three fragments around a record disc with a
/// play triangle. [scale] shrinks it around the center; [solid] paints it
/// in one color (themed icons).
func drawMark(_ ctx: CGContext, scale: CGFloat, solid: CGColor? = nil) {
  let c = CGPoint(x: size / 2, y: size / 2)
  ctx.saveGState()
  ctx.translateBy(x: c.x, y: c.y)
  ctx.scaleBy(x: scale, y: scale)
  ctx.translateBy(x: -c.x, y: -c.y)

  let paint: (CGPath) -> Void = { path in
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    if let solid {
      ctx.setFillColor(solid)
      ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    } else {
      ctx.drawLinearGradient(
        gradient([pink, orange]), start: CGPoint(x: 180, y: 860), end: CGPoint(x: 860, y: 180),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }
    ctx.restoreGState()
  }

  // Ring of three fragments, starting at the top, clockwise.
  let radius: CGFloat = 330
  let width: CGFloat = 74
  let gap = CGFloat.pi / 180 * 22
  let arc = (2 * CGFloat.pi - 3 * gap) / 3
  for i in 0..<3 {
    let start = CGFloat.pi / 2 - gap / 2 - CGFloat(i) * (arc + gap)
    let path = CGMutablePath()
    path.addArc(center: c, radius: radius, startAngle: start, endAngle: start - arc, clockwise: true)
    paint(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1))
  }

  // Record disc with a rounded play triangle cut out of it.
  let disc = CGPath(ellipseIn: CGRect(x: c.x - 205, y: c.y - 205, width: 410, height: 410), transform: nil)
  let triangle = CGMutablePath()
  let h: CGFloat = 190
  let a = CGPoint(x: c.x - h * 0.38, y: c.y + h / 2)
  let b = CGPoint(x: c.x - h * 0.38, y: c.y - h / 2)
  let tip = CGPoint(x: c.x + h * 0.55, y: c.y)
  triangle.move(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
  triangle.addArc(tangent1End: b, tangent2End: tip, radius: 26)
  triangle.addArc(tangent1End: tip, tangent2End: a, radius: 26)
  triangle.addArc(tangent1End: a, tangent2End: b, radius: 26)
  triangle.closeSubpath()
  let discPath = CGMutablePath()
  discPath.addPath(disc)
  discPath.addPath(triangle)
  ctx.saveGState()
  ctx.addPath(discPath)
  ctx.clip(using: .evenOdd)
  if let solid {
    ctx.setFillColor(solid)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
  } else {
    ctx.drawLinearGradient(
      gradient([pink, orange]), start: CGPoint(x: 330, y: 700), end: CGPoint(x: 700, y: 330),
      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
  }
  ctx.restoreGState()
  ctx.restoreGState()
}

func drawBackground(_ ctx: CGContext) {
  ctx.drawLinearGradient(
    gradient([plumTop, plumBottom]), start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
  // Soft pink glow behind the mark.
  ctx.drawRadialGradient(
    gradient([pink.copy(alpha: 0.28)!, pink.copy(alpha: 0)!]),
    startCenter: CGPoint(x: size / 2, y: size / 2), startRadius: 0,
    endCenter: CGPoint(x: size / 2, y: size / 2), endRadius: size * 0.55, options: [])
}

func render(_ name: String, opaque: Bool, _ draw: (CGContext) -> Void) {
  let ctx = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)!
  draw(ctx)
  let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
  let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name)
  try! rep.representation(using: .png, properties: [:])!.write(to: url)
  print("wrote \(url.path)")
}

render("icon.png", opaque: true) { drawBackground($0); drawMark($0, scale: 0.86) }
// flutter_launcher_icons insets adaptive layers by 16%, inside the safe zone.
render("foreground.png", opaque: false) { drawMark($0, scale: 0.86) }
render("monochrome.png", opaque: false) { drawMark($0, scale: 0.86, solid: CGColor(gray: 1, alpha: 1)) }
// Android 12+ splash shows the icon in a circle two thirds of its size.
render("splash_android12.png", opaque: false) { drawMark($0, scale: 0.6) }
render("logo.png", opaque: false) { drawMark($0, scale: 0.95) }

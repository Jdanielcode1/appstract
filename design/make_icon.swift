// Draws the app icon: a whole apple split into three bars, on the app's dark background.
// Usage (from the repo root):
//   swift design/make_icon.swift ConvexDashboard/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
//   swift design/make_icon.swift ConvexDashboard/Resources/Assets.xcassets/Logo.imageset/Logo.png --logo
// `--logo` draws the apple alone on a transparent background, cropped to its bounds (in-app brand mark).
import AppKit
import CoreGraphics

let size = 1024.0
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let logoOnly = CommandLine.arguments.contains("--logo")

func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let background = color(0x171413)
let purple = color(0x8D2676)
let red = color(0xEE342F)
let yellow = color(0xF3B01C)
let stemColor = color(0x7A4B2E)
let leafColor = color(0x4FA65B)

// Apple body: a superellipse (fuller "shoulders" than an oval). Shapes are inset by `r`, then
// stroked 2r with round joins, which rounds every corner by `r`.
let cx = 512.0, cy = 586.0, rx = 320.0, ry = 300.0, n = 2.3
let r = 22.0
let gap = 44.0
let midHalf = 118.0

let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: (logoOnly ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue)!
// Work in top-left-origin coordinates.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

if !logoOnly {
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
}

func roundedFill(_ path: CGPath, _ fill: CGColor) {
    ctx.addPath(path)
    ctx.setFillColor(fill)
    ctx.fillPath()
    ctx.addPath(path)
    ctx.setStrokeColor(fill)
    ctx.setLineWidth(2 * r)
    ctx.setLineJoin(.round)
    ctx.strokePath()
}

let a = rx - r, b = ry - r
let insetEllipse: CGPath = {
    let path = CGMutablePath()
    for i in 0...720 {
        let t = Double(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = CGPoint(x: cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                            y: cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}()
/// Half-height of the body at horizontal offset dx from the center.
func bodyHalfHeight(_ dx: Double) -> Double { b * pow(1 - pow(abs(dx) / a, n), 1 / n) }
let bodyTop = cy - bodyHalfHeight(midHalf - r)

// Stem first, so its base tucks under the middle bar.
let stem = CGMutablePath()
stem.move(to: CGPoint(x: 508, y: bodyTop + 44))
stem.addQuadCurve(to: CGPoint(x: 468, y: bodyTop - 150), control: CGPoint(x: 506, y: bodyTop - 72))
ctx.addPath(stem)
ctx.setStrokeColor(stemColor)
ctx.setLineWidth(30)
ctx.setLineCap(.round)
ctx.strokePath()

// Leaf: an almond attached at the stem, tilted up and right.
let leafBase = CGPoint(x: 538, y: bodyTop - 26), leafTip = CGPoint(x: 704, y: bodyTop - 168)
let leaf = CGMutablePath()
leaf.move(to: leafBase)
leaf.addQuadCurve(to: leafTip, control: CGPoint(x: 676, y: bodyTop - 22))
leaf.addQuadCurve(to: leafBase, control: CGPoint(x: 566, y: bodyTop - 168))
ctx.addPath(leaf)
ctx.setFillColor(leafColor)
ctx.fillPath()

// Outer bars: the inset ellipse cut by a vertical line.
let leftEdge = cx - midHalf - gap - r
let leftRect = CGPath(rect: CGRect(x: 0, y: 0, width: leftEdge, height: size), transform: nil)
roundedFill(insetEllipse.intersection(leftRect), purple)

let rightEdge = cx + midHalf + gap + r
let rightRect = CGPath(rect: CGRect(x: rightEdge, y: 0, width: size - rightEdge, height: size), transform: nil)
roundedFill(insetEllipse.intersection(rightRect), yellow)

// Middle bar: follows the ellipse, with the apple's dimple at top and bottom.
let x0 = cx - midHalf + r, x1 = cx + midHalf - r
let edgeY = bodyHalfHeight(x1 - cx)
let top = cy - edgeY, bottom = cy + edgeY
let middle = CGMutablePath()
middle.move(to: CGPoint(x: x0, y: top))
middle.addQuadCurve(to: CGPoint(x: x1, y: top), control: CGPoint(x: cx, y: top + 58))
middle.addLine(to: CGPoint(x: x1, y: bottom))
middle.addQuadCurve(to: CGPoint(x: x0, y: bottom), control: CGPoint(x: cx, y: bottom - 46))
middle.closeSubpath()
roundedFill(middle, red)

var image = ctx.makeImage()!
if logoOnly {
    // Crop to the drawn pixels plus a hairline of padding.
    let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var minX = Int(size), minY = Int(size), maxX = 0, maxY = 0
    for y in 0..<Int(size) {
        for x in 0..<Int(size) where bytes[y * ctx.bytesPerRow + x * 4 + 3] > 0 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    image = image.cropping(to: CGRect(x: minX - 4, y: minY - 4, width: maxX - minX + 9, height: maxY - minY + 9))!
}
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

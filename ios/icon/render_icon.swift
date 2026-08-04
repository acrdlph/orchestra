// Final orchestra app icon: the v2a signal mark over the board canvas, with the
// four status hues. Emits the three iOS appearances: light (own background),
// dark (transparent — the system supplies the dark backdrop), tinted (white on
// transparent, system applies the tint).
import AppKit
import CoreGraphics

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let S: CGFloat = 1024

func color(_ rgb: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255, alpha: a)
}
let canvas: UInt32 = 0x0D0D0D
let warmWhite: UInt32 = 0xE8E6E3
let terracotta: UInt32 = 0xD97757
let sage: UInt32 = 0x87B386
let amber: UInt32 = 0xD4B06A
let cyan: UInt32 = 0x7FB3C8

func render(_ name: String, opaque: Bool, monochrome: Bool) {
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    if opaque {
        ctx.setFillColor(color(canvas))
        ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))
        let colors = [color(terracotta, 0.10), color(terracotta, 0.0)] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: colors, locations: [0, 1])!
        ctx.saveGState()
        ctx.translateBy(x: S * 0.70, y: S * 0.88)
        ctx.scaleBy(x: 1.0, y: 0.55)
        ctx.drawRadialGradient(grad, startCenter: .zero, startRadius: 0,
                               endCenter: .zero, endRadius: S * 0.62, options: [])
        ctx.restoreGState()
    }

    // the mark
    let rect = CGRect(x: S * 0.17, y: S * 0.42, width: S * 0.64, height: S * 0.22)
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }
    let lw = S * 0.056
    let a = pt(0.02, 0.42), b = pt(0.30, 0.70), c = pt(0.54, 0.22), d = pt(0.88, 0.62)
    let p = CGMutablePath()
    p.move(to: a); p.addLine(to: b); p.addLine(to: c); p.addLine(to: d)
    let markColor: CGColor = monochrome ? color(0xFFFFFF) : color(warmWhite)
    ctx.setStrokeColor(markColor)
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.addPath(p); ctx.strokePath()
    let dl = hypot(d.x - c.x, d.y - c.y)
    let ux = (d.x - c.x) / dl, uy = (d.y - c.y) / dl
    let px = -uy, py = ux
    let L = lw * 2.2
    let back = CGPoint(x: d.x - ux * L, y: d.y - uy * L)
    let w1 = CGPoint(x: back.x + px * L * 0.72, y: back.y + py * L * 0.72)
    let w2 = CGPoint(x: back.x - px * L * 0.72, y: back.y - py * L * 0.72)
    let h = CGMutablePath()
    h.move(to: w1); h.addLine(to: d); h.addLine(to: w2)
    ctx.addPath(h); ctx.strokePath()

    // the status row
    let hues: [UInt32] = [sage, terracotta, amber, cyan]
    let dotR = S * 0.027
    let gap = S * 0.105
    let startX = S / 2 - gap * 1.5
    for (i, hue) in hues.enumerated() {
        ctx.setFillColor(monochrome ? color(0xFFFFFF, 0.8) : color(hue))
        let x = startX + CGFloat(i) * gap
        ctx.fillEllipse(in: CGRect(x: x - dotR, y: S * 0.30 - dotR,
                                   width: dotR * 2, height: dotR * 2))
    }

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
    print("wrote \(name)")
}

render("AppIcon.png", opaque: true, monochrome: false)
render("AppIcon-dark.png", opaque: false, monochrome: false)
render("AppIcon-tinted.png", opaque: false, monochrome: true)

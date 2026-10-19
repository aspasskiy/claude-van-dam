// Draws the app icon: the Epic Split. Usage: swift tools/make-icon.swift <out.png>  (1024×1024)
// The Epic Split: a man in a full side split, arms folded, heels on the roofs of two trucks,
// against a setting sun. Built left-half-first and mirrored, so it stays perfectly symmetric.
// FIGURE_ONLY=1 renders the silhouette alone, black on white.
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon.png"

// ---------- helpers ----------
func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func grad(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: stops.map { $0.1 } as CFArray, locations: stops.map { $0.0 })!
}
func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func clipped(_ path: CGPath, _ body: () -> Void) { ctx.saveGState(); ctx.addPath(path); ctx.clip(); body(); ctx.restoreGState() }
func linear(_ path: CGPath, _ g: CGGradient, _ a: CGPoint, _ b: CGPoint) {
    clipped(path) { ctx.drawLinearGradient(g, start: a, end: b, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]) }
}
func radial(_ path: CGPath, _ g: CGGradient, _ c: CGPoint, _ r: CGFloat, from r0: CGFloat = 0) {
    clipped(path) { ctx.drawRadialGradient(g, startCenter: c, startRadius: r0, endCenter: c, endRadius: r, options: [.drawsAfterEndLocation]) }
}
func fill(_ path: CGPath, _ c: CGColor) { ctx.addPath(path); ctx.setFillColor(c); ctx.fillPath() }
func poly(_ pts: [CGPoint]) -> CGPath { let p = CGMutablePath(); p.addLines(between: pts); p.closeSubpath(); return p }
func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath { CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), transform: nil) }
func mirrorX(_ p: CGPath) -> CGPath { var t = CGAffineTransform(translationX: S, y: 0).scaledBy(x: -1, y: 1); return p.copy(using: &t)! }
func both(_ p: CGPath) -> CGPath { p.union(mirrorX(p)) }
func shifted(_ p: CGPath, _ dx: CGFloat, _ dy: CGFloat) -> CGPath { var t = CGAffineTransform(translationX: dx, y: dy); return p.copy(using: &t)! }


// Apple-style continuous-corner rounded square: straight sides, superellipse corners.
func appleSquircle(_ r: CGRect, radius: CGFloat = 185) -> CGPath {
    let R = radius * 1.528, n: CGFloat = 2.9
    let p = CGMutablePath()
    let corners: [(CGPoint, CGFloat)] = [(P(r.maxX - R, r.maxY - R), 0), (P(r.minX + R, r.maxY - R), .pi / 2),
                                         (P(r.minX + R, r.minY + R), .pi), (P(r.maxX - R, r.minY + R), 3 * .pi / 2)]
    for (i, (c, a0)) in corners.enumerated() {
        for k in 0...60 {
            let t = a0 + CGFloat(k) / 60 * .pi / 2, ct = cos(t), st = sin(t)
            let pt = P(c.x + R * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n), c.y + R * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n))
            if i == 0 && k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
    }
    p.closeSubpath(); return p
}

// ---------- palette ----------
let ink = rgb(0x1B1140)          // figure + cab faces
let sunCore = rgb(0xFFF7DE)

// ---------- layout ----------
let body = appleSquircle(CGRect(x: 100, y: 100, width: 824, height: 824))
let horizon: CGFloat = 330
let sunC = P(512, 640), sunR: CGFloat = 228
let roof: CGFloat = 432, bot: CGFloat = 40
let trailerTop: CGFloat = 496                           // the trailer box behind each cab
let stand = trailerTop                                    // where the shoes rest
let innerBot: CGFloat = 318, innerTop: CGFloat = 378, outerBot: CGFloat = 0, outerTop: CGFloat = 60  // cab edges at y=bot and y=482
func innerX(_ y: CGFloat) -> CGFloat { innerBot + (innerTop - innerBot) * (y - bot) / (482 - bot) }

// ---------- drop shadow + base ----------
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.32))
fill(body, rgb(0xE06A4E))
ctx.restoreGState()

clipped(body) {
    // Sky.
    linear(body, grad([(0, rgb(0xD8365E)), (0.45, rgb(0xFF7A45)), (0.85, rgb(0xFFC56A)), (1, rgb(0xFFE3A0))]), P(0, 924), P(0, horizon))
    // Sun + halo.
    radial(body, grad([(0, rgb(0xFFF3C8, 0.9)), (0.45, rgb(0xFFE2A0, 0.35)), (1, rgb(0xFFB070, 0))]), sunC, 520)
    radial(circle(sunC, sunR), grad([(0, rgb(0xFFFDF2)), (0.8, sunCore), (1, rgb(0xFFEBC0))]), sunC, sunR)
    // Ground: charcoal road with a dashed centre line running to the horizon.
    let ground = CGPath(rect: CGRect(x: 0, y: 0, width: S, height: horizon), transform: nil)
    linear(ground, grad([(0, rgb(0x6A3A3A)), (1, rgb(0xB0624A))]), P(0, 100), P(0, horizon))   // dusty verge
    linear(CGPath(rect: CGRect(x: 0, y: horizon - 40, width: S, height: 40), transform: nil),
           grad([(0, rgb(0x4A3540, 0)), (1, rgb(0xFFB878, 0.35))]), P(0, horizon - 40), P(0, horizon))
    // The road narrows toward the horizon, edged with pale lines that run right up to it.
    let roadL = (P(110, 60), P(474, horizon)), roadR = (P(914, 60), P(550, horizon))
    linear(poly([roadL.0, roadR.0, roadR.1, roadL.1]),
           grad([(0, rgb(0x15131F)), (0.8, rgb(0x2A2433)), (1, rgb(0x4A3540))]), P(0, 100), P(0, horizon))   // charcoal road
    for (a, b) in [roadL, roadR] {
        ctx.move(to: a); ctx.addLine(to: b)
        ctx.setStrokeColor(rgb(0xFFE3B0, 0.85)); ctx.setLineWidth(4); ctx.strokePath()
    }
    func halfWidth(_ y: CGFloat) -> CGFloat { 3 + (horizon - y) * 0.075 }
    for (y0, y1) in [(CGFloat(60), CGFloat(150)), (186, 246), (272, 302), (318, 326)] {
        ctx.addPath(poly([P(512 - halfWidth(y0), y0), P(512 + halfWidth(y0), y0), P(512 + halfWidth(y1), y1), P(512 - halfWidth(y1), y1)]))
        ctx.setFillColor(rgb(0xFFC56A, 0.9))
        ctx.fillPath()
    }

    // ---------- truck cabs ----------
    let cab = CGMutablePath()
    cab.move(to: P(outerBot, bot))
    cab.addLine(to: P(outerTop - 4, roof - 60))
    cab.addQuadCurve(to: P(outerTop + 50, roof), control: P(outerTop, roof))
    let cabIn = innerX(roof)
    cab.addLine(to: P(cabIn - 46, roof))
    cab.addQuadCurve(to: P(cabIn + 2, roof - 54), control: P(cabIn, roof - 2))
    cab.addLine(to: P(innerBot, bot))
    cab.closeSubpath()
    // Windshield under a tall sleeper-cab brow.
    let wsB: CGFloat = 268, wsT: CGFloat = 378, wr: CGFloat = 24
    let wsL: CGFloat = 92
    // Rounded quad: corners rounded with tangent arcs so the slanted inner side meets them without a kink.
    let ws = CGMutablePath()
    let wsBL = P(wsL, wsB), wsTL = P(wsL + 6, wsT), wsTR = P(innerX(wsT) - 26, wsT), wsBR = P(innerX(wsB) - 26, wsB)
    ws.move(to: P((wsBL.x + wsBR.x) / 2, wsB))
    ws.addArc(tangent1End: wsBL, tangent2End: wsTL, radius: wr)
    ws.addArc(tangent1End: wsTL, tangent2End: wsTR, radius: wr)
    ws.addArc(tangent1End: wsTR, tangent2End: wsBR, radius: wr)
    ws.addArc(tangent1End: wsBR, tangent2End: wsBL, radius: wr)
    ws.closeSubpath()
    // One headlight at the cab's inner lower corner; its twin sits beyond the icon's edge.
    let lamp = CGPath(roundedRect: CGRect(x: 236, y: 150, width: 64, height: 30), cornerWidth: 15, cornerHeight: 15, transform: nil)

    // Trailer box behind each cab: taller and a touch wider — what makes it a truck, not a bus.
    let trailer = CGMutablePath()
    do {
        let tIn = { (y: CGFloat) in innerX(y) }, r: CGFloat = 32
        trailer.move(to: P(-20, bot))
        trailer.addLine(to: P(-20, trailerTop))
        trailer.addLine(to: P(tIn(trailerTop) - r, trailerTop))  // softly rounded corner peeks out behind the cab
        trailer.addQuadCurve(to: P(tIn(trailerTop - r), trailerTop - r), control: P(tIn(trailerTop), trailerTop))
        trailer.addLine(to: P(tIn(bot), bot))
        trailer.closeSubpath()
    }
    for t in [trailer, mirrorX(trailer)] {
        let m = t !== trailer
        // Trailer sits a step back, in a touch of shade; the inner edge catches a warm shadow line.
        fill(t, rgb(0xFFE2BE))
        clipped(t) { linear(shifted(t, m ? 6 : -6, -6), grad([(0, rgb(0xF0624A)), (1, rgb(0xC9443A))]), P(0, trailerTop), P(0, roof)) }
    }
    for m in [false, true] {
        func M(_ p: CGPath) -> CGPath { m ? mirrorX(p) : p }
        let c = M(cab), w = M(ws)
        ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 16, color: rgb(0x8A2E5A, 0.45))
        fill(c, rgb(0xFFFFFF)); ctx.restoreGState()
        linear(c, grad([(0, rgb(0xFFFBF6)), (0.45, rgb(0xFFE6D6)), (1, rgb(0xF5B49C))]), P(0, roof), P(0, bot))
        linear(c, grad([(0, rgb(0xE07A86, 0)), (1, rgb(0xD0607A, 0.35))]), P(m ? S - innerX(roof) + 60 : innerX(roof) - 60, 0), P(m ? S - innerX(roof) : innerX(roof), 0))
        linear(w, grad([(0, rgb(0x3E4A6A)), (0.5, rgb(0x283050)), (1, rgb(0x1E2440))]), P(0, wsT), P(0, wsB))
        // The sunset caught in the glass: a soft warm band along the top.
        linear(w, grad([(0, rgb(0xFF9A6A, 0.55)), (1, rgb(0xFF9A6A, 0))]), P(0, wsT), P(0, wsT - 50))
        ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 18, color: rgb(0xFFB040, 0.8))
        fill(M(lamp), rgb(0xFFD45A)); ctx.restoreGState()
    }

    // ---------- figure ----------
    // Final coordinates: centre x=512, heels on y=stand. Left half, mirrored.
    let st = stand
    // Leg: straight underside on the roof, top edge tapering from hip to ankle.
    let leg = CGMutablePath()
    leg.move(to: P(514, st + 6))
    leg.addLine(to: P(220, st))
    leg.addLine(to: P(220, st + 25))
    leg.addCurve(to: P(468, st + 72), control1: P(316, st + 34), control2: P(414, st + 50))
    leg.addLine(to: P(514, st + 70))
    leg.closeSubpath()
    // Flexed foot: heel on the roof, a short wedge leaning out as it rises to the toes.
    let foot = CGMutablePath()
    foot.move(to: P(224, st))
    foot.addLine(to: P(192, st))
    foot.addQuadCurve(to: P(177, st + 15), control: P(178, st))
    foot.addCurve(to: P(170, st + 52), control1: P(175, st + 26), control2: P(171, st + 40))
    foot.addCurve(to: P(188, st + 58), control1: P(169, st + 62), control2: P(182, st + 64))
    foot.addCurve(to: P(220, st + 25), control1: P(194, st + 44), control2: P(204, st + 27))
    foot.addLine(to: P(240, st + 20))
    foot.closeSubpath()
    // Torso: hip → waist → elbow (forearms folded across) → upper arm → deltoid → trapezius → neck.
    let torso = CGMutablePath()
    torso.move(to: P(514, st + 14))
    torso.addLine(to: P(436, st + 14))
    torso.addLine(to: P(436, st + 59))
    torso.addCurve(to: P(468, st + 94), control1: P(456, st + 64), control2: P(468, st + 78))   // groin crease, tangent to the thigh
    torso.addLine(to: P(468, st + 104))
    torso.addCurve(to: P(444, st + 112), control1: P(462, st + 109), control2: P(452, st + 109))
    torso.addCurve(to: P(432, st + 132), control1: P(436, st + 115), control2: P(432, st + 122))
    torso.addCurve(to: P(438, st + 188), control1: P(432, st + 152), control2: P(434, st + 172))
    torso.addCurve(to: P(462, st + 212), control1: P(442, st + 204), control2: P(450, st + 212))
    torso.addCurve(to: P(497, st + 232), control1: P(478, st + 214), control2: P(492, st + 222))
    torso.addLine(to: P(497, st + 250))
    torso.addLine(to: P(514, st + 250))
    torso.closeSubpath()
    // Head: short crop, ears, jaw angle, chin.
    let head = CGMutablePath()
    head.move(to: P(514, st + 307))
    head.addCurve(to: P(487, st + 284), control1: P(498, st + 307), control2: P(487, st + 300))   // crown
    head.addCurve(to: P(486, st + 270), control1: P(487, st + 278), control2: P(486, st + 274))   // temple
    head.addCurve(to: P(487, st + 254), control1: P(483, st + 268), control2: P(483, st + 257))   // ear
    head.addCurve(to: P(497, st + 242), control1: P(489, st + 250), control2: P(492, st + 245))   // jaw
    head.addCurve(to: P(514, st + 235), control1: P(502, st + 238), control2: P(507, st + 235))   // chin
    head.closeSubpath()
    let cut = CGMutablePath()
    cut.move(to: P(456, st + 186))
    cut.addCurve(to: P(476, st + 150), control1: P(455, st + 166), control2: P(459, st + 150))
    cut.addLine(to: P(512, st + 150))
    let slot = both(cut.copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 1))
    // Legs drawn long, then pulled in toward the centre line to sit in proportion with the torso.
    var shorten = CGAffineTransform(translationX: 514, y: 0).scaledBy(x: 0.88, y: 1).translatedBy(x: -514, y: 0)
    let half = leg.union(foot).copy(using: &shorten)!.union(torso).union(head)
    var grow = CGAffineTransform(translationX: 512, y: st).scaledBy(x: 1.05, y: 1.05).translatedBy(x: -512, y: -st)
    let figure = both(half).subtracting(slot).copy(using: &grow)!
    if ProcessInfo.processInfo.environment["FIGURE_ONLY"] != nil {
        ctx.resetClip()
        fill(CGPath(rect: CGRect(x: 0, y: 0, width: S, height: S), transform: nil), rgb(0xFFFFFF))
        fill(figure, rgb(0x000000))
    } else {
        ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 16, color: rgb(0xFFF6DA, 0.85))
        fill(figure, ink); ctx.restoreGState()
    }
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

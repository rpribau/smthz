// extract_layers.swift: cut the smthz icon layers out of icon/icon.png (read-only).
//
// Deterministic: same input, same output. No randomness, no external deps
// (Foundation + CoreGraphics + ImageIO only).
//
// Usage (from the repo root):
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
//     swift assets/AppIcon/tools/extract_layers.swift [icon/icon.png] [assets/AppIcon/smthz.icon/Assets]
//
// Output (1024 x 1024 canvas, the full Icon Composer macOS square):
//   figure.png  the bust as a transparent PNG (photographic raster, hard silhouette)
//   rings.svg   the broken circle arcs around the head (vector, fitted to the pixels)
//   dashes.svg  the vertical dash/dot columns (vector, one rounded rect per blob)
//
// The baked glass tile of the reference (rim, gloss, black matte) is NOT carried
// over: the system applies the mask and Liquid Glass. The reference tile
// (x 80..1174, y 78..1172 in source pixels) is mapped onto the 1024 canvas.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
let inputPath = args.count > 1 ? args[1] : "icon/icon.png"
let outputDir = args.count > 2 ? args[2] : "assets/AppIcon/smthz.icon/Assets"

// Source square that corresponds to the icon canvas (the reference tile).
let cropX = 80.0, cropY = 78.0, cropSize = 1094.0
let canvas = 1024
let scale = Double(canvas) / cropSize
// Leave a deliberate system-mask safe margin around the bust. The source
// figure nearly fills the baked tile; the reference itself shows the bust
// smaller within the tile, with space around the shoulders and sides.
let figureScale = 0.84

// Figure silhouette in source pixels (top-left origin), measured on a 50 px grid.
// Clockwise from the bottom-left; the bottom edge runs below the canvas.
let figurePolygon: [(Double, Double)] = [
    (220, 1200), (175, 1196), (135, 1187), (103, 1170), (80, 1145), (66, 1115), (60, 1070), (60, 942), (110, 937), (230, 893), (350, 845), (420, 800), (447, 765),
    (447, 700), (440, 642), (420, 617), (397, 592), (382, 556), (372, 500), (372, 456), (380, 440),
    (378, 400), (380, 330), (395, 262), (420, 215), (460, 176), (510, 151), (580, 136), (650, 133),
    (710, 141), (755, 170), (775, 190), (810, 200), (840, 230), (857, 280), (866, 340), (865, 400),
    (858, 440), (866, 460), (869, 500), (863, 545), (850, 585), (832, 610), (838, 625), (842, 700),
    (832, 745), (805, 765), (860, 820), (905, 857), (1000, 895), (1100, 930), (1150, 945), (1195, 952),
    (1195, 1070), (1189, 1115), (1175, 1145), (1152, 1170), (1120, 1187), (1080, 1196), (1035, 1200),
]
// The reference's glass rim crosses the suit. Clean area = rounded rect inside
// the rim. Outside it, the shirt/tie band is extended downwards (vertical edge
// extension) and the suit fades into a flat suit tone sampled from the jacket.
let clean = (x0: 126.0, x1: 1128.0, y1: 1108.0, radius: 150.0)
let shirtBand = 470...760
let fadeWidth = 24.0
let suitSample = (x0: 150, y0: 960, x1: 420, y1: 1100)

// Ring/dash detection: pixels brighter than their local mean (top-hat), outside
// the figure, inside the tile interior. Local contrast ignores the smooth gloss.
let detectContrast = 28, detectWindow = 40
let detectRect = (x0: 166, y0: 198, x1: 1100, y1: 900)

// MARK: - IO

func loadImage(_ path: String) -> CGImage {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        fatalError("cannot read \(path)")
    }
    return img
}

func writePNG(_ image: CGImage, _ path: String) {
    guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                    UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot write \(path)")
    }
    CGImageDestinationAddImage(dst, image, nil)
    guard CGImageDestinationFinalize(dst) else { fatalError("cannot finalize \(path)") }
}

// MARK: - Pixel buffers (top-left origin, row-major)

let ref = loadImage(inputPath)
let W = ref.width, H = ref.height
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

var rgba = [UInt8](repeating: 0, count: W * H * 4)
rgba.withUnsafeMutableBytes { raw in
    let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: srgb, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(ref, in: CGRect(x: 0, y: 0, width: W, height: H))
}

func luma(_ x: Int, _ y: Int) -> UInt8 {
    let i = (y * W + x) * 4
    return UInt8((Int(rgba[i]) * 299 + Int(rgba[i + 1]) * 587 + Int(rgba[i + 2]) * 114) / 1000)
}

// Polygon mask rasterised by CoreGraphics (anti-aliased), in source pixels.
func polygonMask(_ points: [(Double, Double)], dilate: Double = 0) -> [UInt8] {
    var mask = [UInt8](repeating: 0, count: W * H)
    mask.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        // Flip so that (0,0) is the top-left, matching the buffer rows.
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
        path.closeSubpath()
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(path); ctx.fillPath()
        if dilate > 0 {
            ctx.setStrokeColor(gray: 1, alpha: 1); ctx.setLineWidth(dilate * 2); ctx.setLineJoin(.round)
            ctx.addPath(path); ctx.strokePath()
        }
    }
    return mask
}

// MARK: - Figure layer

func buildFigure() -> CGImage {
    let mask = polygonMask(figurePolygon)
    // Flat suit tone: median luma of the jacket sample.
    var samples: [UInt8] = []
    for y in suitSample.y0..<suitSample.y1 { for x in suitSample.x0..<suitSample.x1 where mask[y * W + x] > 127 { samples.append(luma(x, y)) } }
    samples.sort()
    let suit = Double(samples[samples.count / 2])
    // Distance outside the clean rounded rect (bottom corners rounded; open at the top).
    func outside(_ x: Double, _ y: Double) -> Double {
        let r = clean.radius
        let dx = max(clean.x0 + r - x, x - (clean.x1 - r), 0)
        let dy = max(y - (clean.y1 - r), 0)
        if dy > 0 && dx > 0 { return (dx * dx + dy * dy).squareRoot() - r }
        return max(clean.x0 - x, x - clean.x1, y - clean.y1)
    }
    var src = [UInt8](repeating: 0, count: W * H * 4)
    for y in 0..<H {
        for x in 0..<W {
            let a = Int(mask[y * W + x])
            guard a > 0 else { continue }
            let di = (y * W + x) * 4
            var px = [Double(rgba[di]), Double(rgba[di + 1]), Double(rgba[di + 2])]
            if shirtBand.contains(x) {
                let si = (min(y, Int(clean.y1)) * W + x) * 4
                px = [Double(rgba[si]), Double(rgba[si + 1]), Double(rgba[si + 2])]
            } else {
                let t = min(max(outside(Double(x), Double(y)) / fadeWidth + 1, 0), 1)
                px = px.map { $0 * (1 - t) + suit * t }
            }
            // Premultiplied alpha.
            for c in 0..<3 { src[di + c] = UInt8((px[c] * Double(a) / 255).rounded()) }
            src[di + 3] = UInt8(a)
        }
    }
    let provider = CGDataProvider(data: Data(src) as CFData)!
    let full = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: srgb,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
    let out = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    out.interpolationQuality = .high
    // Place the crop square onto the canvas (CG origin bottom-left).
    let fullDrawW = Double(W) * scale, fullDrawH = Double(H) * scale
    let drawW = fullDrawW * figureScale, drawH = fullDrawH * figureScale
    let x = Double(canvas) / 2 * (1 - figureScale) - cropX * scale * figureScale
    let originalY = Double(canvas) + cropY * scale - fullDrawH
    let y = Double(canvas) / 2 * (1 - figureScale) + originalY * figureScale
    out.draw(full, in: CGRect(x: x, y: y, width: drawW, height: drawH))
    return out.makeImage()!
}

// MARK: - Rings and dashes (vector)

struct Blob { var pixels: [(Int, Int)] = []; var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min }

func detectBlobs() -> [Blob] {
    let figure = polygonMask(figurePolygon, dilate: 6)
    // Integral image of luma for O(1) box means.
    var integral = [Int](repeating: 0, count: (W + 1) * (H + 1))
    for y in 0..<H {
        var row = 0
        for x in 0..<W {
            row += Int(luma(x, y))
            integral[(y + 1) * (W + 1) + x + 1] = integral[y * (W + 1) + x + 1] + row
        }
    }
    func boxMean(_ x: Int, _ y: Int) -> Int {
        let x0 = max(0, x - detectWindow), y0 = max(0, y - detectWindow)
        let x1 = min(W, x + detectWindow + 1), y1 = min(H, y + detectWindow + 1)
        let sum = integral[y1 * (W + 1) + x1] - integral[y0 * (W + 1) + x1] - integral[y1 * (W + 1) + x0] + integral[y0 * (W + 1) + x0]
        return sum / ((x1 - x0) * (y1 - y0))
    }
    var on = [Bool](repeating: false, count: W * H)
    for y in detectRect.y0..<detectRect.y1 {
        for x in detectRect.x0..<detectRect.x1 where figure[y * W + x] == 0 && Int(luma(x, y)) - boxMean(x, y) >= detectContrast {
            on[y * W + x] = true
        }
    }
    if let debugPath = ProcessInfo.processInfo.environment["SMTHZ_ICON_DEBUG"] {
        // Debug overlay: detected pixels in red over the reference.
        var dbg = rgba
        for i in 0..<(W * H) where on[i] { dbg[i * 4] = 255; dbg[i * 4 + 1] = 0; dbg[i * 4 + 2] = 0 }
        for i in 0..<(W * H) where figure[i] > 127 { dbg[i * 4 + 2] = UInt8(min(255, Int(dbg[i * 4 + 2]) + 60)) }
        let ctx = CGContext(data: &dbg, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: srgb,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        writePNG(ctx.makeImage()!, debugPath)
    }
    var seen = [Bool](repeating: false, count: W * H)
    var blobs: [Blob] = []
    for start in 0..<(W * H) where on[start] && !seen[start] {
        var b = Blob(); var stack = [start]; seen[start] = true
        while let i = stack.popLast() {
            let x = i % W, y = i / W
            b.pixels.append((x, y))
            b.minX = min(b.minX, x); b.maxX = max(b.maxX, x); b.minY = min(b.minY, y); b.maxY = max(b.maxY, y)
            for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < W, ny < H else { continue }
                let j = ny * W + nx
                if on[j] && !seen[j] { seen[j] = true; stack.append(j) }
            }
        }
        if b.pixels.count >= 60 { blobs.append(b) }
    }
    return blobs.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
}

// Algebraic least-squares circle fit (Kasa) over a set of points.
func fitCircle(_ pts: [(Int, Int)]) -> (cx: Double, cy: Double, r: Double) {
    var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0, sxz = 0.0, syz = 0.0, sz = 0.0
    let n = Double(pts.count)
    for (ix, iy) in pts {
        let x = Double(ix), y = Double(iy), z = x * x + y * y
        sx += x; sy += y; sxx += x * x; syy += y * y; sxy += x * y; sxz += x * z; syz += y * z; sz += z
    }
    // Solve [sxx sxy sx; sxy syy sy; sx sy n] [a b c] = [sxz syz sz]
    let m = [[sxx, sxy, sx, sxz], [sxy, syy, sy, syz], [sx, sy, n, sz]]
    var a = m
    for c in 0..<3 {
        let p = (c..<3).max { abs(a[$0][c]) < abs(a[$1][c]) }!
        a.swapAt(c, p)
        for r in 0..<3 where r != c {
            let f = a[r][c] / a[c][c]
            for k in c..<4 { a[r][k] -= f * a[c][k] }
        }
    }
    let A = a[0][3] / a[0][0], B = a[1][3] / a[1][1], C = a[2][3] / a[2][2]
    let cx = A / 2, cy = B / 2
    return (cx, cy, (C + cx * cx + cy * cy).squareRoot())
}

func toCanvas(_ v: Double, _ origin: Double) -> Double { (v - origin) * scale }
func f(_ v: Double) -> String { String(format: "%.1f", v) }

let blobs = detectBlobs()
var arcs: [Blob] = [], dashes: [Blob] = []
for b in blobs {
    let w = b.maxX - b.minX + 1, h = b.maxY - b.minY + 1
    // Dashes are short vertical capsules; arcs are long curved strokes.
    if w <= 22 && h <= 140 { dashes.append(b) } else if b.pixels.count >= 400 { arcs.append(b) }
}

// One circle centre shared by every arc (they are concentric in the reference).
let circle = fitCircle(arcs.flatMap { $0.pixels })
func angle(_ p: (Int, Int)) -> Double { atan2(Double(p.1) - circle.cy, Double(p.0) - circle.cx) }
func radius(_ p: (Int, Int)) -> Double { (pow(Double(p.0) - circle.cx, 2) + pow(Double(p.1) - circle.cy, 2)).squareRoot() }
// Angular interval of each blob (unwrapped around its mean direction), then merge
// blobs that touch: a gloss edge in the reference can split one arc in two.
typealias Arc = (a0: Double, a1: Double, pixels: [(Int, Int)])
let blobArcs: [Arc] = arcs.map { b in
    let angles = b.pixels.map(angle)
    let mean = atan2(angles.map { sin($0) }.reduce(0, +), angles.map { cos($0) }.reduce(0, +))
    let rel = angles.map { a -> Double in var d = a - mean; while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }; return d }
    return (mean + rel.min()!, mean + rel.max()!, b.pixels)
}.sorted { $0.a0 < $1.a0 }
var mergedArcs: [Arc] = []
for arc in blobArcs {
    if let last = mergedArcs.last, arc.a0 <= last.a1 + 0.02 {
        mergedArcs[mergedArcs.count - 1] = (last.a0, max(last.a1, arc.a1), last.pixels + arc.pixels)
    } else {
        mergedArcs.append(arc)
    }
}
// All arcs share the fitted centre. Stroke width = median radial thickness over
// 0.01 rad bins of the long arcs (checked by hand: the left arc is 26-27 source
// px wide on row 560, i.e. ~25 canvas px).
typealias Geometry = (cx: Double, cy: Double, r: Double, a0: Double, a1: Double, thickness: [Double])
func geometry(_ pixels: [(Int, Int)], cx: Double, cy: Double) -> Geometry {
    let angles = pixels.map { atan2(Double($0.1) - cy, Double($0.0) - cx) }
    let radii = pixels.map { (pow(Double($0.0) - cx, 2) + pow(Double($0.1) - cy, 2)).squareRoot() }
    let mean = atan2(angles.map { sin($0) }.reduce(0, +), angles.map { cos($0) }.reduce(0, +))
    let rel = angles.map { a -> Double in var d = a - mean; while d > .pi { d -= 2 * .pi }; while d < -.pi { d += 2 * .pi }; return d }
    var bins: [Int: (lo: Double, hi: Double)] = [:]
    for (i, d) in rel.enumerated() {
        let k = Int((d * 100).rounded(.down)), r = radii[i]
        let cur = bins[k] ?? (r, r)
        bins[k] = (min(cur.lo, r), max(cur.hi, r))
    }
    return (cx, cy, radii.sorted()[radii.count / 2], mean + rel.min()!, mean + rel.max()!, bins.values.map { $0.hi - $0.lo + 1 })
}
let geometries: [Geometry] = mergedArcs.map { geometry($0.pixels, cx: circle.cx, cy: circle.cy) }
let thickness = geometries.filter { $0.a1 - $0.a0 > 0.4 }.flatMap { $0.thickness }.sorted()
let strokeWidth = thickness.isEmpty ? 26 : thickness[thickness.count / 2]
var ringPaths: [String] = []
for g in geometries {
    // Trim half the stroke width so the round caps land on the measured ends.
    let trim = (strokeWidth / 2) / g.r
    let s = g.a0 + trim, e = g.a1 - trim
    guard e > s else { continue }
    let p0 = (g.cx + g.r * cos(s), g.cy + g.r * sin(s)), p1 = (g.cx + g.r * cos(e), g.cy + g.r * sin(e))
    let large = (e - s) > .pi ? 1 : 0
    let rc = g.r * scale
    ringPaths.append("M \(f(toCanvas(p0.0, cropX))) \(f(toCanvas(p0.1, cropY))) A \(f(rc)) \(f(rc)) 0 \(large) 1 \(f(toCanvas(p1.0, cropX))) \(f(toCanvas(p1.1, cropY)))")
}
let ringRadius = geometries.map { $0.r }.sorted()[geometries.count / 2]
let ringWidth = strokeWidth * scale

var dashRects: [String] = []
for b in dashes {
    let x = toCanvas(Double(b.minX), cropX), y = toCanvas(Double(b.minY), cropY)
    let w = Double(b.maxX - b.minX + 1) * scale, h = Double(b.maxY - b.minY + 1) * scale
    dashRects.append("<rect x=\"\(f(x))\" y=\"\(f(y))\" width=\"\(f(w))\" height=\"\(f(h))\" rx=\"\(f(w / 2))\"/>")
}

let header = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(canvas)\" height=\"\(canvas)\" viewBox=\"0 0 \(canvas) \(canvas)\">"
let ringsSVG = header + "\n  <g fill=\"none\" stroke=\"#FFFFFF\" stroke-width=\"\(f(ringWidth))\" stroke-linecap=\"round\">\n"
    + ringPaths.map { "    <path d=\"\($0)\"/>" }.joined(separator: "\n") + "\n  </g>\n</svg>\n"
let dashesSVG = header + "\n  <g fill=\"#FFFFFF\">\n" + dashRects.map { "    " + $0 }.joined(separator: "\n") + "\n  </g>\n</svg>\n"

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
writePNG(buildFigure(), outputDir + "/figure.png")
try! ringsSVG.write(toFile: outputDir + "/rings.svg", atomically: true, encoding: .utf8)
try! dashesSVG.write(toFile: outputDir + "/dashes.svg", atomically: true, encoding: .utf8)

print("circle centre (\(f(circle.cx)), \(f(circle.cy))) r \(f(ringRadius)) source px; \(ringPaths.count) arcs from \(arcs.count) blobs, \(dashes.count) dashes, ring width \(f(ringWidth)) canvas px")
for b in blobs { print("  blob x \(b.minX)-\(b.maxX) y \(b.minY)-\(b.maxY) n \(b.pixels.count)") }
print("wrote \(outputDir)/figure.png, rings.svg, dashes.svg")

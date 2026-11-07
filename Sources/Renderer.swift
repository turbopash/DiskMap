import AppKit
import CoreText

struct MapFilter: Equatable {
    var query = ""             // в нижнем регистре
    var category: Int? = nil
    var ext: UInt64? = nil
    var isActive: Bool { !query.isEmpty || category != nil || ext != nil }

    func matches(file n: FileNode) -> Bool {
        if let c = category, Int(n.category) != c { return false }
        if let e = ext, n.ext != e { return false }
        return true
    }
}

struct RenderParams {
    var style = MapStyle.cushion
    var colorMode = ColorMode.category
    var labels = true
    var ambient: Float = 0.34
    var brightness: Float = 1.12
    var filter = MapFilter()
    var now = Int64(Date().timeIntervalSince1970)
}

private func hsv(_ h: Float, _ s: Float, _ v: Float) -> RGB {
    let i = Int(h * 6) % 6
    let f = h * 6 - Float(Int(h * 6))
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    switch i {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
}

/// Цвет расширения стабилен между запусками: зависит только от самого расширения.
func extColor(_ k: UInt64) -> RGB {
    if k == 0 { return catColors[catOther] }
    var x = k &* 0x9E37_79B9_7F4A_7C15
    x ^= x >> 29
    x = x &* 0xBF58_476D_1CE4_E5B9
    x ^= x >> 32
    let h = Float(x & 0xFFFF) / 65536
    let s = 0.62 + 0.3 * Float((x >> 16) & 0xFF) / 255
    let v = 0.72 + 0.26 * Float((x >> 24) & 0xFF) / 255
    return hsv(h, s, v)
}

/// Свежие файлы красные, старые синие. Шкала логарифмическая, до 10 лет.
func ageColor(_ mtime: Int64, now: Int64) -> RGB {
    if mtime <= 0 { return catColors[catOther] }
    let days = max(0, Float(now - mtime) / 86400)
    let t = min(1, log(1 + days) / log(1 + 3650))
    return hsv(0.66 * t, 0.82, 0.95)
}

func tileColor(_ t: Tile, _ p: RenderParams) -> RGB {
    let n = t.node
    if n.isSynthetic { return catColors[Int(n.category)] }
    if t.rest > 0 {
        switch p.colorMode {
        case .category, .ext: return catColors[catOther]
        default: break
        }
    }
    switch p.colorMode {
    case .category:
        return catColors[Int(n.category)]
    case .ext:
        return n.isFolder ? catColors[Int(n.category)] : extColor(n.ext)
    case .age:
        return ageColor(n.mtime, now: p.now)
    case .topFolder:
        let i = max(0, Int(t.top))
        return hsv(Float((Double(i) * 0.618_034).truncatingRemainder(dividingBy: 1)), 0.68, 0.92)
    case .depth:
        return hsv(Float((Double(t.depth) * 0.13).truncatingRemainder(dividingBy: 1)), 0.70, 0.92)
    }
}

enum Renderer {
    static func render(_ layout: TreemapLayout, _ p: RenderParams) -> CGImage? {
        let W = Int(layout.width), H = Int(layout.height)
        guard W > 0, H > 0 else { return nil }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let data = ctx.data else { return nil }
        let px = data.bindMemory(to: UInt32.self, capacity: W * H)
        let bg: UInt32 = 0xFF18_1412
        px.initialize(repeating: bg, count: W * H)

        let tiles = layout.tiles
        let dimmed = computeDimmed(tiles, p.filter)

        // Рамки папок рисуются первыми, листья поверх них.
        for (i, t) in tiles.enumerated() where t.frame {
            let (x0, y0, x1, y1) = bounds(t, W, H)
            let dim = dimmed.map { $0[i] } ?? false
            let c = pack(dim ? (0.13, 0.13, 0.14) : frameColor(t.depth))
            for y in y0..<y1 {
                let row = px + y * W
                for x in x0..<x1 { row[x] = c }
            }
        }

        // Большие плитки режутся на полосы, чтобы нагрузка делилась между ядрами.
        var tasks: [(tile: Int32, y0: Int32, y1: Int32)] = []
        tasks.reserveCapacity(tiles.count)
        for (i, t) in tiles.enumerated() where t.count == 0 {
            let (x0, y0, x1, y1) = bounds(t, W, H)
            if x1 <= x0 || y1 <= y0 { continue }
            let rows = max(1, 65536 / (x1 - x0))
            var y = y0
            while y < y1 {
                let e = min(y1, y + rows)
                tasks.append((Int32(i), Int32(y), Int32(e)))
                y = e
            }
        }

        let lightLen = (1.0 + 1.0 + 100.0 as Float).squareRoot()
        let lx = -1 / lightLen, ly = -1 / lightLen, lz = 10 / lightLen
        let ia = p.ambient, id = (1 - p.ambient) * p.brightness
        let flat = p.style == .flat
        let chunk = 256
        let chunks = (tasks.count + chunk - 1) / chunk

        tiles.withUnsafeBufferPointer { tp in
            tasks.withUnsafeBufferPointer { kp in
                DispatchQueue.concurrentPerform(iterations: chunks) { ci in
                    let end = min(kp.count, (ci + 1) * chunk)
                    for k in (ci * chunk)..<end {
                        let task = kp[k]
                        let i = Int(task.tile)
                        let t = tp[i]
                        var c = tileColor(t, p)
                        if let d = dimmed, d[i] {
                            let g = (c.r + c.g + c.b) / 3 * 0.26
                            c = (g, g, g + 0.01)
                        }
                        let (x0, _, x1, _) = bounds(t, W, H)
                        let yEnd = Int(task.y1)
                        if flat {
                            let (_, _, _, by1) = bounds(t, W, H)
                            let fill = pack(c)
                            let edge = pack((c.r * 0.62, c.g * 0.62, c.b * 0.62))
                            for y in Int(task.y0)..<yEnd {
                                let row = px + y * W
                                if y == by1 - 1 { for x in x0..<x1 { row[x] = edge } }
                                else {
                                    for x in x0..<x1 { row[x] = fill }
                                    row[x1 - 1] = edge
                                }
                            }
                            continue
                        }
                        let ax = 2 * t.sx2, ay = 2 * t.sy2
                        for y in Int(task.y0)..<yEnd {
                            let row = px + y * W
                            let ny = -(ay * (Float(y) + 0.5) + t.sy1)
                            let nyl = ny * ly + lz
                            let ny2 = ny * ny + 1
                            var nx = -(ax * (Float(x0) + 0.5) + t.sx1)
                            for x in x0..<x1 {
                                let cosA = (nx * lx + nyl) / (nx * nx + ny2).squareRoot()
                                let v = ia + id * max(0, cosA)
                                let hi = max(0, v - 1) * 0.9
                                let m = min(v, 1)
                                let r = min(1, c.r * m + hi), g = min(1, c.g * m + hi), b = min(1, c.b * m + hi)
                                row[x] = UInt32(r * 255) | UInt32(g * 255) << 8 | UInt32(b * 255) << 16 | 0xFF00_0000
                                nx -= ax
                            }
                        }
                    }
                }
            }
        }

        if p.labels || layout.opts.headers { drawLabels(ctx, layout, p, dimmed) }
        return ctx.makeImage()
    }

    @inline(__always) private static func bounds(_ t: Tile, _ W: Int, _ H: Int) -> (Int, Int, Int, Int) {
        let x0 = max(0, Int((t.x).rounded())), y0 = max(0, Int((t.y).rounded()))
        let x1 = min(W, Int((t.x + t.w).rounded())), y1 = min(H, Int((t.y + t.h).rounded()))
        return (x0, y0, x1, y1)
    }

    @inline(__always) private static func pack(_ c: RGB) -> UInt32 {
        UInt32(c.r * 255) | UInt32(c.g * 255) << 8 | UInt32(c.b * 255) << 16 | 0xFF00_0000
    }

    private static func frameColor(_ depth: Int16) -> RGB {
        let v = max(0.14, 0.34 - Float(depth) * 0.035)
        return (v, v, v + 0.02)
    }

    /// nil, если фильтра нет. true для плиток, которые надо приглушить.
    private static func computeDimmed(_ tiles: [Tile], _ f: MapFilter) -> [Bool]? {
        guard f.isActive else { return nil }
        var nameHit = [Bool](repeating: false, count: tiles.count)
        var dim = [Bool](repeating: true, count: tiles.count)
        for i in 0..<tiles.count {
            let t = tiles[i]
            var hit = t.parent >= 0 && nameHit[Int(t.parent)]
            if !hit && !f.query.isEmpty && t.rest == 0 {
                hit = t.node.name.range(of: f.query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            nameHit[i] = hit
            if t.rest > 0 || t.node.isSynthetic { continue }
            let nameOK = f.query.isEmpty || hit
            dim[i] = !(nameOK && f.matches(file: t.node))
        }
        for i in 0..<tiles.count where tiles[i].frame { dim[i] = false }
        return dim
    }

    private static func drawLabels(_ ctx: CGContext, _ layout: TreemapLayout, _ p: RenderParams, _ dimmed: [Bool]?) {
        let s = CGFloat(layout.opts.scale)
        let H = CGFloat(layout.height)
        let nameFont = CTFontCreateUIFontForLanguage(.system, 11 * s, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 11 * s, nil)
        let boldFont = CTFontCreateCopyWithSymbolicTraits(nameFont, 0, nil, .boldTrait, .boldTrait) ?? nameFont
        let sizeFont = CTFontCreateCopyWithAttributes(nameFont, 10 * s, nil, nil)

        func line(_ text: String, _ font: CTFont, width: CGFloat) -> CTLine? {
            let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorFromContextAttributeName: true]
            let a = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
            let l = CTLineCreateWithAttributedString(a)
            if CTLineGetTypographicBounds(l, nil, nil, nil) <= Double(width) { return l }
            let dots = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, "…" as CFString, attrs as CFDictionary)!)
            return CTLineCreateTruncatedLine(l, Double(width), .middle, dots)
        }

        func draw(_ l: CTLine, x: CGFloat, top: CGFloat, ascent: CGFloat, dark: Bool) {
            ctx.setFillColor(dark ? CGColor(gray: 0.05, alpha: 1) : CGColor(gray: 1, alpha: 1))
            ctx.setShadow(offset: .zero, blur: 2 * s, color: dark ? CGColor(gray: 1, alpha: 0.5) : CGColor(gray: 0, alpha: 0.8))
            ctx.textPosition = CGPoint(x: x, y: H - top - ascent)
            CTLineDraw(l, ctx)
        }

        let tiles = layout.tiles
        // Заголовки папок
        for (i, t) in tiles.enumerated() where t.frame {
            let w = CGFloat(t.w) - 8 * s
            let title = t.node.name + "  " + fmtSize(t.node.size)
            guard let l = line(title, boldFont, width: w) else { continue }
            _ = i
            draw(l, x: CGFloat(t.x) + 4 * s, top: CGFloat(t.y) + 1.5 * s, ascent: 11 * s, dark: false)
        }
        guard p.labels else { return }

        var cand: [(Int, Float)] = []
        for (i, t) in tiles.enumerated() where t.count == 0 && t.w >= 46 * Float(s) && t.h >= 16 * Float(s) {
            if dimmed?[i] ?? false { continue }
            cand.append((i, t.w * t.h))
        }
        cand.sort { $0.1 > $1.1 }
        for (i, _) in cand.prefix(500) {
            let t = tiles[i]
            let c = tileColor(t, p)
            let lum = 0.3 * c.r + 0.59 * c.g + 0.11 * c.b
            let dark = lum > 0.62
            let w = CGFloat(t.w) - 10 * s
            let name = t.rest > 0 ? "\(fmtInt(t.rest)) мелких" : (t.depth == 0 ? t.node.displayName : t.node.name)
            let two = CGFloat(t.h) >= 32 * s
            let x = CGFloat(t.x) + 5 * s
            let top = CGFloat(t.y) + 3 * s
            guard let l = line(name, nameFont, width: w) else { continue }
            draw(l, x: x, top: top, ascent: 11 * s, dark: dark)
            if two, t.rest == 0, let l2 = line(fmtSize(t.node.size), sizeFont, width: w) {
                draw(l2, x: x, top: top + 13 * s, ascent: 10 * s, dark: dark)
            }
        }
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }
}

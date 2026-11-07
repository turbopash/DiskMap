import Foundation
import CoreGraphics

struct LayoutOptions: Equatable {
    var scale: Float = 2
    var headers = false
    var showFree = true
    var packagesAsFiles = false
    var maxDepth = 0
    var height: Float = 0.16
    var falloff: Float = 0.75
    var leafRidge: Float = 0.24
    var minTile: Float = 3
}

struct Tile {
    var x: Float, y: Float, w: Float, h: Float
    var sx1: Float, sx2: Float, sy1: Float, sy2: Float
    var node: FileNode
    var parent: Int32
    var first: Int32
    var count: Int32
    var top: Int32      // индекс ветки первого уровня, для раскраски по верхней папке
    var rest: Int32     // >0: плитка объединяет столько мелких объектов
    var depth: Int16
    var frame: Bool     // папка с рамкой и заголовком
}

/// Squarified treemap (Bruls, Huizing, van Wijk) с поверхностями для cushion-шейдинга.
/// Координаты в пикселях, начало слева сверху.
final class TreemapLayout {
    private(set) var tiles: [Tile] = []
    let root: FileNode
    let width: Float, height: Float
    let opts: LayoutOptions
    private let minArea: Double

    init(root: FileNode, width: Float, height: Float, opts: LayoutOptions) {
        self.root = root; self.width = width; self.height = height; self.opts = opts
        minArea = Double(opts.minTile * opts.minTile)
        tiles.reserveCapacity(4096)
        var t = Tile(x: 0, y: 0, w: width, h: height, sx1: 0, sx2: 0, sy1: 0, sy2: 0, node: root,
                     parent: -1, first: -1, count: 0, top: -1, rest: 0, depth: 0, frame: false)
        Self.ridge(&t, opts.height)
        tiles.append(t)
        layout(0, x: 0, y: 0, w: Double(width), h: Double(height), ridge: opts.height * opts.falloff)
        if tiles[0].count == 0 { Self.ridge(&tiles[0], opts.leafRidge) }
    }

    private static func ridge(_ t: inout Tile, _ h: Float) {
        guard t.w > 0, t.h > 0 else { return }
        t.sx1 += 4 * h * (2 * t.x + t.w) / t.w
        t.sx2 -= 4 * h / t.w
        t.sy1 += 4 * h * (2 * t.y + t.h) / t.h
        t.sy2 -= 4 * h / t.h
    }

    private func descends(_ n: FileNode, depth: Int) -> Bool {
        if n.children.isEmpty || !n.isFolder { return false }
        if opts.maxDepth > 0 && depth >= opts.maxDepth { return false }
        if opts.packagesAsFiles && n.kind == .package { return false }
        return n.size > 0
    }

    private func layout(_ idx: Int, x x0: Double, y y0: Double, w w0: Double, h h0: Double, ridge: Float) {
        let parent = tiles[idx]
        let node = parent.node
        guard descends(node, depth: Int(parent.depth)) else { return }

        var kids = node.children
        var total = Double(node.size)
        if idx == 0 {
            if !opts.showFree { kids = kids.filter { !$0.isSynthetic } }
            total = kids.reduce(0.0) { $0 + Double($1.size) }
        } else {
            kids = kids.filter { !$0.isSynthetic }
        }
        guard total > 0, w0 > 0, h0 > 0 else { return }

        let scale = w0 * h0 / total
        let n = kids.count
        let start = tiles.count
        var x = x0, y = y0, w = w0, h = h0
        var i = 0
        let depth = parent.depth + 1

        func add(_ node: FileNode, _ rx: Double, _ ry: Double, _ rw: Double, _ rh: Double, rest: Int32) {
            var t = Tile(x: Float(rx), y: Float(ry), w: Float(rw), h: Float(rh),
                         sx1: parent.sx1, sx2: parent.sx2, sy1: parent.sy1, sy2: parent.sy2,
                         node: node, parent: Int32(idx), first: -1, count: 0,
                         top: idx == 0 ? Int32(tiles.count - start) : parent.top,
                         rest: rest, depth: depth, frame: false)
            Self.ridge(&t, ridge)
            tiles.append(t)
        }

        while i < n {
            let s0 = Double(kids[i].size)
            if s0 <= 0 { break }
            if s0 * scale < minArea || w < 1 || h < 1 {
                var rest = 0
                for k in i..<n where kids[k].size > 0 { rest += 1 }
                add(node, x, y, w, h, rest: Int32(rest))
                i = n
                break
            }
            let side = min(w, h)
            let side2 = side * side
            let big = s0 * scale
            var j = i, sum = 0.0, best = Double.infinity
            while j < n {
                let s = Double(kids[j].size) * scale
                if s <= 0 || s < minArea { break }
                let ns = sum + s
                let a2 = ns * ns
                let worst = max(side2 * big / a2, a2 / (side2 * s))
                if j > i && worst > best { break }
                best = worst; sum = ns; j += 1
            }
            let thick = sum / side
            var off = 0.0
            let vertical = w >= h
            for k in i..<j {
                let len = Double(kids[k].size) * scale / thick
                if vertical { add(kids[k], x, y + off, thick, len, rest: 0) }
                else { add(kids[k], x + off, y, len, thick, rest: 0) }
                off += len
            }
            if vertical { x += thick; w -= thick } else { y += thick; h -= thick }
            i = j
        }

        let end = tiles.count
        tiles[idx].first = Int32(start)
        tiles[idx].count = Int32(end - start)

        let s = opts.scale
        for c in start..<end {
            let t = tiles[c]
            guard t.rest == 0, descends(t.node, depth: Int(t.depth)) else {
                // Своя выпуклость листа не зависит от глубины, иначе глубокие файлы сливаются.
                Self.ridge(&tiles[c], opts.leafRidge)
                continue
            }
            var cx = Double(t.x), cy = Double(t.y), cw = Double(t.w), ch = Double(t.h)
            if opts.headers && t.w >= 56 * s && t.h >= 34 * s {
                tiles[c].frame = true
                let pad = Double(s), head = Double(15 * s)
                cx += pad; cw -= 2 * pad; cy += head; ch -= head + pad
            }
            layout(c, x: cx, y: cy, w: cw, h: ch, ridge: ridge * opts.falloff)
        }
    }

    /// Самая глубокая плитка в точке (пиксели).
    func hit(x: Float, y: Float) -> Int? {
        guard x >= 0, y >= 0, x < width, y < height, !tiles.isEmpty else { return nil }
        var i = 0
        while true {
            let t = tiles[i]
            if t.count == 0 { return i }
            var next = -1
            let a = Int(t.first), b = a + Int(t.count)
            var c = a
            while c < b {
                let k = tiles[c]
                if x >= k.x && y >= k.y && x < k.x + k.w && y < k.y + k.h { next = c; break }
                c += 1
            }
            if next < 0 { return i }
            i = next
        }
    }

    /// Плитка узла или ближайшего видимого родителя.
    func tileIndex(for node: FileNode) -> Int? {
        var chain: [FileNode] = []
        var n: FileNode? = node
        while let c = n, c !== root { chain.append(c); n = c.parent }
        guard n === root else { return nil }
        var i = 0
        for want in chain.reversed() {
            let t = tiles[i]
            guard t.count > 0 else { break }
            var found = -1
            for c in Int(t.first)..<Int(t.first) + Int(t.count) where tiles[c].node === want && tiles[c].rest == 0 {
                found = c; break
            }
            if found < 0 { break }
            i = found
        }
        return i
    }

    func rect(_ i: Int) -> CGRect {
        let t = tiles[i]
        return CGRect(x: CGFloat(t.x), y: CGFloat(t.y), width: CGFloat(t.w), height: CGFloat(t.h))
    }
}

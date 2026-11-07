import AppKit

private var failures = 0
private func check(_ ok: Bool, _ what: String) {
    print((ok ? "  ok   " : "  FAIL ") + what)
    if !ok { failures += 1 }
}

private func sh(_ cmd: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh"); p.arguments = ["-c", cmd]
    let o = Pipe(); p.standardOutput = o
    try? p.run()
    let d = o.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: d, as: UTF8.self)
}

func writePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

func runSelfTest() -> Int32 {
    let dir = NSTemporaryDirectory() + "diskmap-test-\(getpid())"
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir + "/a/b/empty", withIntermediateDirectories: true)
    try? fm.createDirectory(atPath: dir + "/Demo.app/Contents", withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let rnd = Data((0..<(3 << 20)).map { _ in UInt8.random(in: 0...255) })
    try? rnd.write(to: URL(fileURLWithPath: dir + "/a/big.mov"))
    try? rnd.write(to: URL(fileURLWithPath: dir + "/a/b/copy.mov"))
    try? Data(count: 10_000).write(to: URL(fileURLWithPath: dir + "/a/b/заметка.TXT"))
    try? Data(count: 5_000).write(to: URL(fileURLWithPath: dir + "/Demo.app/Contents/bin"))
    _ = sh("ln '\(dir)/a/big.mov' '\(dir)/a/hard.mov'; ln -s big.mov '\(dir)/a/sym'; mkfile -n 50m '\(dir)/a/sparse.dat'")

    print("Сканер")
    guard let r = Scanner().scan(path: dir, excludes: []) else { print("  FAIL скан"); return 1 }
    let root = r.root
    let du = Int64(sh("du -sk '\(dir)' | cut -f1").trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    check(abs(root.alloc / 1024 - du) <= 8, "занято совпадает с du: \(root.alloc / 1024) КБ и \(du) КБ")
    check(root.fileCount == 7, "файлов 7, получено \(root.fileCount)")
    let a = root.children.first { $0.name == "a" }!
    let hard = a.children.filter { $0.name == "big.mov" || $0.name == "hard.mov" }
    check(hard.map(\.alloc).filter { $0 == 0 }.count == 1, "жёсткая ссылка посчитана один раз")
    check(a.children.first { $0.name == "sym" }?.kind == .symlink, "символическая ссылка не раскрыта")
    let b = a.children.first { $0.name == "b" }!
    let note = b.children.first { $0.name == "заметка.TXT" }!
    check(Int(note.category) == catDoc && extName(note.ext) == "txt", "кириллица и регистр расширения")
    check(note.path == dir + "/a/b/заметка.TXT" || note.path.hasSuffix("/a/b/заметка.TXT"), "путь собирается: \(note.path)")
    check(root.children.first { $0.name == "Demo.app" }?.kind == .package, "пакет распознан")
    check(zip(a.children, a.children.dropFirst()).allSatisfy { $0.size >= $1.size }, "дети отсортированы")

    print("Удаление из дерева")
    let before = root.alloc, sub = note.alloc
    treeLock.write { detach(note) }
    check(root.alloc == before - sub && note.parent == nil, "размер вычтен у всех родителей")

    print("Дубликаты")
    let dups = DuplicateFinder().find(in: root, minSize: 1 << 20, progress: { _, _ in }) ?? []
    let dupNames = Set(dups.flatMap { $0.files.map(\.name) })
    check(dups.count == 1 && dupNames.contains("copy.mov"), "найдена группа копий: \(dupNames.sorted())")

    print("Раскладка")
    let fake = FileNode(name: "/fake", kind: .dir, parent: nil)
    var total: Int64 = 0
    for i in 0..<3000 {
        let n = FileNode(name: "f\(i).mp4", kind: .file, parent: fake)
        n.alloc = Int64(1 + Int(pow(Double(3000 - i), 2.2))); total += n.alloc
        fake.children.append(n)
    }
    fake.alloc = total
    var o = LayoutOptions(); o.scale = 1
    let W: Float = 1200, H: Float = 800
    let lay = TreemapLayout(root: fake, width: W, height: H, opts: o)
    let kids = lay.tiles.dropFirst()
    let area = kids.reduce(0.0) { $0 + Double($1.w * $1.h) }
    check(abs(area - Double(W * H)) < Double(W * H) * 0.001, "плитки покрывают всю площадь")
    var worst = 0.0
    for t in kids where t.rest == 0 {
        let want = Double(t.node.alloc) / Double(total) * Double(W * H)
        worst = max(worst, abs(Double(t.w * t.h) - want) / want)
    }
    check(worst < 0.001, "площадь пропорциональна размеру, ошибка \(worst)")
    let sample = kids.prefix(600).map { $0 }
    var overlap = false
    for i in 0..<sample.count { for j in (i + 1)..<sample.count {
        let p = sample[i], q = sample[j]
        if p.x + 0.01 < q.x + q.w && q.x + 0.01 < p.x + p.w && p.y + 0.01 < q.y + q.h && q.y + 0.01 < p.y + p.h { overlap = true }
    } }
    check(!overlap, "плитки не пересекаются")
    let big = kids.prefix(200).map { max($0.w / $0.h, $0.h / $0.w) }.reduce(0, +) / 200
    check(big < 3, "плитки близки к квадрату, среднее \(big)")
    let hitOK = kids.prefix(500).allSatisfy { t in
        guard let i = lay.hit(x: t.x + t.w / 2, y: t.y + t.h / 2) else { return false }
        return lay.tiles[i].node === t.node
    }
    check(hitOK, "попадание мышью находит нужную плитку")
    check(lay.tiles.contains { $0.rest > 0 } || lay.tiles.count == 3001, "мелочь объединяется в одну плитку")

    print("Рендер")
    let img = Renderer.render(lay, RenderParams())
    check(img?.width == 1200 && img?.height == 800, "изображение нужного размера")
    if let img, let d = img.dataProvider?.data as Data? {
        var colors = Set<UInt32>()
        d.withUnsafeBytes { p in
            let u = p.bindMemory(to: UInt32.self)
            for i in stride(from: 0, to: u.count, by: 97) { colors.insert(u[i]) }
        }
        check(colors.count > 100, "есть объёмный шейдинг: \(colors.count) оттенков")
    }
    print(failures == 0 ? "Все проверки пройдены" : "Ошибок: \(failures)")
    return failures == 0 ? 0 : 1
}

/// Скан без интерфейса: время, число файлов, картинка карты.
func runSnapshot(_ args: [String]) -> Int32 {
    guard args.count >= 2 else { print("--snapshot <папка> <out.png> [исключения…]"); return 2 }
    let s = Scanner()
    guard let r = s.scan(path: args[0], excludes: Array(args.dropFirst(2))) else { print("скан не удался"); return 1 }
    print("файлов \(r.root.fileCount), занято \(fmtSize(r.root.alloc)), логически \(fmtSize(r.root.logical)), нет доступа \(r.deniedCount), время \(String(format: "%.2f", r.duration)) с")
    for c in r.root.children.prefix(12) { print("  \(fmtSize(c.size))\t\(c.name)") }
    var o = LayoutOptions(); o.scale = 2
    o.headers = ProcessInfo.processInfo.environment["HEADERS"] != nil
    let t0 = Date()
    let lay = TreemapLayout(root: r.root, width: 2400, height: 1500, opts: o)
    let t1 = Date()
    var p = RenderParams()
    if let m = ProcessInfo.processInfo.environment["MODE"], let i = Int(m), let c = ColorMode(rawValue: i) { p.colorMode = c }
    guard let img = Renderer.render(lay, p) else { return 1 }
    print("плиток \(lay.tiles.count), раскладка \(Int(t1.timeIntervalSince(t0) * 1000)) мс, рендер \(Int(Date().timeIntervalSince(t1) * 1000)) мс")
    writePNG(img, args[1])
    return 0
}

/// Значок программы рисуется тем же рендером, что и карта.
func makeIcon(_ path: String) -> Int32 {
    let root = FileNode(name: "/icon", kind: .dir, parent: nil)
    let sizes: [(Int64, Int)] = [(40, catVideo), (24, catDoc), (16, catImage), (11, catCode), (8, catAudio), (6, catArchive), (4, catApp)]
    for (i, (s, c)) in sizes.enumerated() {
        let n = FileNode(name: "\(i)", kind: .file, parent: root)
        n.alloc = s; n.category = UInt8(c)
        root.children.append(n); root.alloc += s
    }
    var o = LayoutOptions(); o.scale = 1; o.leafRidge = 0.32; o.minTile = 1
    var p = RenderParams(); p.labels = false; p.ambient = 0.42; p.brightness = 1.15
    let lay = TreemapLayout(root: root, width: 824, height: 824, opts: o)
    guard let map = Renderer.render(lay, p) else { return 1 }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
    let r = CGRect(x: 100, y: 100, width: 824, height: 824)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.clip()
    ctx.draw(map, in: r)
    guard let img = ctx.makeImage() else { return 1 }
    writePNG(img, path)
    return 0
}

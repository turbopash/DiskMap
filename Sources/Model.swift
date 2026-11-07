import AppKit

// MARK: - Категории файлов

let catVideo = 0, catAudio = 1, catImage = 2, catDoc = 3, catArchive = 4
let catCode = 5, catApp = 6, catData = 7, catOther = 8, catFree = 9, catUnknown = 10
let catCount = 11

let catNames = ["Видео", "Аудио", "Изображения", "Документы", "Архивы и образы",
                "Код", "Приложения", "Данные и кеши", "Прочее", "Свободно", "Не просканировано"]

typealias RGB = (r: Float, g: Float, b: Float)

let catColors: [RGB] = [
    (0.93, 0.26, 0.27), (0.68, 0.33, 0.90), (0.98, 0.60, 0.13), (0.20, 0.52, 0.96),
    (0.93, 0.80, 0.18), (0.18, 0.76, 0.42), (0.10, 0.74, 0.80), (0.56, 0.62, 0.30),
    (0.60, 0.61, 0.66), (0.20, 0.23, 0.26), (0.40, 0.40, 0.44),
]

func nsColor(_ c: RGB) -> NSColor {
    NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
}

/// Расширение упаковано в UInt64: до 8 символов ASCII в нижнем регистре. Так оно не занимает память строкой.
@inline(__always) func extKey(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt64 {
    var i = n - 1
    let low = max(1, n - 9)
    while i >= low {
        if p[i] == 46 {
            var k: UInt64 = 0
            var j = i + 1
            if j == n { return 0 }
            while j < n {
                var c = p[j]
                if c >= 128 { return 0 }
                if c >= 65 && c <= 90 { c += 32 }
                k = (k << 8) | UInt64(c)
                j += 1
            }
            return k
        }
        i -= 1
    }
    return 0
}

func extKey(_ s: String) -> UInt64 {
    let name = "x." + s
    return Array(name.utf8).withUnsafeBufferPointer { extKey($0.baseAddress!, $0.count) }
}

func extName(_ k: UInt64) -> String {
    if k == 0 { return "" }
    var bytes: [UInt8] = []
    var v = k
    while v != 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
    return String(decoding: bytes, as: UTF8.self)
}

private func table(_ cat: Int, _ s: String) -> [(UInt64, UInt8)] {
    s.split(separator: " ").map { (extKey(String($0)), UInt8(cat)) }
}

let extCategory: [UInt64: UInt8] = {
    var d: [UInt64: UInt8] = [:]
    let all = table(catVideo, "mp4 m4v mov avi mkv wmv flv webm mpg mpeg mts m2ts ts vob 3gp ogv braw r3d mxf prores insv lrv")
        + table(catAudio, "mp3 m4a aac wav aiff aif flac ogg opus wma alac caf mid midi m4b m4p")
        + table(catImage, "jpg jpeg png gif tiff tif bmp heic heif webp raw cr2 cr3 nef arw dng orf raf psd psb ai svg ico icns exr tga xcf sketch")
        + table(catDoc, "pdf doc docx xls xlsx ppt pptx odt ods odp rtf txt md pages numbers key epub mobi fb2 djvu csv tex")
        + table(catArchive, "zip rar 7z tar gz tgz bz2 xz zst dmg iso img sparseimage sparsebundle pkg xip cab jar ipsw vmdk vdi qcow2 ova")
        + table(catCode, "c h cc cpp hpp m mm swift py js jsx ts tsx java kt go rs rb php sh zsh bash pl lua cs html htm css scss vue xml yaml yml toml sql ipynb gradle cmake")
        + table(catApp, "app dylib so a o framework bundle kext exe dll msi appex plugin xpc nib car metallib tbd")
        + table(catData, "db sqlite sqlite3 sqlitedb wal shm log plist json dat bin cache tmp idx pack pak bak nsf realm ldb map pt onnx safetensor gguf ckpt mlmodel npy h5 parquet")
    for (k, v) in all where d[k] == nil { d[k] = v }
    d[extKey("ts")] = UInt8(catVideo)
    return d
}()

let packageExts: Set<UInt64> = Set(["app", "bundle", "framework", "photoslibrary", "fcpbundle", "imovielibrary",
    "tvlibrary", "musiclibrary", "logicx", "band", "plugin", "kext", "xcarchive", "sparsebundle", "rtfd",
    "pages", "numbers", "key", "appex", "xpc", "photolibrary", "aplibrary"].map { extKey($0) })

// MARK: - Узел дерева

enum NodeKind: UInt8 { case file, dir, package, symlink, free, unknown }

/// Глобальный режим подсчёта: true — логический размер, false — занято на диске.
var gUseLogical = false

final class FileNode {
    var name: String
    unowned(unsafe) var parent: FileNode?
    var children: [FileNode] = []
    var alloc: Int64 = 0
    var logical: Int64 = 0
    var mtime: Int64 = 0
    var ext: UInt64 = 0
    var fileCount: Int32 = 0
    var kind: NodeKind
    var category: UInt8 = UInt8(catOther)
    var denied = false

    init(name: String, kind: NodeKind, parent: FileNode?) {
        self.name = name; self.kind = kind; self.parent = parent
    }

    @inline(__always) var size: Int64 { gUseLogical ? logical : alloc }
    var isFolder: Bool { kind == .dir || kind == .package }
    var isSynthetic: Bool { kind == .free || kind == .unknown }

    var path: String {
        if isSynthetic { return "" }
        var parts: [String] = []
        var n = self
        while let p = n.parent { parts.append(n.name); n = p }
        var s = n.name
        for part in parts.reversed() {
            if !s.hasSuffix("/") { s += "/" }
            s += part
        }
        return s
    }

    var displayName: String {
        if parent != nil { return name }
        if name == "/" { return FileManager.default.displayName(atPath: "/") }
        return (name as NSString).lastPathComponent
    }

    var rootNode: FileNode {
        var n = self
        while let p = n.parent { n = p }
        return n
    }

    func isDescendant(of a: FileNode) -> Bool {
        var n: FileNode? = self
        while let c = n { if c === a { return true }; n = c.parent }
        return false
    }

    var depthBelowRoot: Int {
        var d = 0; var n = self
        while let p = n.parent { d += 1; n = p }
        return d
    }

    /// Доля от родителя. Свободное место считается от всего объёма карты.
    var shareOfParent: Double {
        guard let p = parent else { return 1 }
        var total = p.size
        if isSynthetic || p.parent == nil {
            total += p.children.reduce(Int64(0)) { $0 + ($1.isSynthetic ? $1.size : 0) }
        }
        return total > 0 ? Double(size) / Double(total) : 0
    }
}

/// Блокировка дерева: фоновые обходы читают, главный поток изредка меняет.
final class TreeLock {
    private var l = pthread_rwlock_t()
    init() { pthread_rwlock_init(&l, nil) }
    func read<T>(_ f: () -> T) -> T { pthread_rwlock_rdlock(&l); defer { pthread_rwlock_unlock(&l) }; return f() }
    func write<T>(_ f: () -> T) -> T { pthread_rwlock_wrlock(&l); defer { pthread_rwlock_unlock(&l) }; return f() }
}
let treeLock = TreeLock()

/// Убирает узел из дерева и вычитает его размер у всех родителей. Вызывать внутри write-блокировки.
func detach(_ node: FileNode) {
    guard let parent = node.parent else { return }
    parent.children.removeAll { $0 === node }
    if !node.isSynthetic {
        var p: FileNode? = parent
        while let c = p {
            c.alloc -= node.alloc; c.logical -= node.logical; c.fileCount -= node.fileCount
            p = c.parent
        }
    }
    node.parent = nil
}

/// Подменяет узел свежей версией. Вызывать внутри write-блокировки.
func replace(_ old: FileNode, with new: FileNode) {
    guard let parent = old.parent, let i = parent.children.firstIndex(where: { $0 === old }) else { return }
    new.name = old.name
    new.parent = parent
    parent.children[i] = new
    let da = new.alloc - old.alloc, dl = new.logical - old.logical, df = new.fileCount - old.fileCount
    var p: FileNode? = parent
    while let c = p {
        c.alloc += da; c.logical += dl; c.fileCount += df
        c.children.sort { $0.size > $1.size }
        p = c.parent
    }
    old.parent = nil
}

func resortTree(_ n: FileNode) {
    if n.children.isEmpty { return }
    n.children.sort { $0.size > $1.size }
    for c in n.children where !c.children.isEmpty { resortTree(c) }
}

// MARK: - Форматирование

func fmtSize(_ v: Int64) -> String {
    let a = Double(abs(v))
    let units = ["Б", "КБ", "МБ", "ГБ", "ТБ", "ПБ"]
    if a < 1000 { return "\(v) Б" }
    var x = a; var u = 0
    while x >= 1000 && u < units.count - 1 { x /= 1000; u += 1 }
    let s = x >= 100 ? String(format: "%.0f", x) : x >= 10 ? String(format: "%.1f", x) : String(format: "%.2f", x)
    return (v < 0 ? "-" : "") + s.replacingOccurrences(of: ".", with: ",") + " " + units[u]
}

private let intFormatter: NumberFormatter = {
    let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "ru_RU"); return f
}()
func fmtInt<T: BinaryInteger>(_ v: T) -> String { intFormatter.string(from: NSNumber(value: Int64(v))) ?? "\(v)" }

private let dateFormatter: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "dd.MM.yyyy"; return f
}()
func fmtDate(_ t: Int64) -> String { t <= 0 ? "—" : dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(t))) }

func fmtPercent(_ v: Double) -> String {
    let p = v * 100
    let s = p >= 10 ? String(format: "%.0f", p) : String(format: "%.1f", p)
    return s.replacingOccurrences(of: ".", with: ",") + " %"
}

/// Склонение: 1 файл, 2 файла, 5 файлов.
func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let a = n % 100, b = n % 10
    if a >= 11 && a <= 14 { return many }
    if b == 1 { return one }
    if b >= 2 && b <= 4 { return few }
    return many
}

// MARK: - Настройки

enum ColorMode: Int, CaseIterable {
    case category, ext, age, topFolder, depth
    var title: String { ["По типу файла", "По расширению", "По возрасту", "По верхней папке", "По глубине"][rawValue] }
}

enum MapStyle: Int { case cushion, flat }

extension Notification.Name {
    /// userInfo["layout"] == true, если изменилась раскладка, иначе только перекраска.
    static let dmSettings = Notification.Name("DiskMapSettings")
}

final class Settings {
    static let s = Settings()
    private let d = UserDefaults.standard

    private init() {
        d.register(defaults: [
            "colorMode": 0, "style": 0, "labels": true, "headers": false, "showFree": true,
            "packagesAsFiles": false, "maxDepth": 0, "logical": false, "bubble": true,
            "cushionHeight": 0.16, "cushionFalloff": 0.75, "ambient": 0.34, "brightness": 1.12,
            "minTile": 3.0, "excluded": [String](), "recents": [String](),
        ])
        gUseLogical = d.bool(forKey: "logical")
    }

    private func changed(layout: Bool) {
        NotificationCenter.default.post(name: .dmSettings, object: nil, userInfo: ["layout": layout])
    }

    var colorMode: ColorMode {
        get { ColorMode(rawValue: d.integer(forKey: "colorMode")) ?? .category }
        set { d.set(newValue.rawValue, forKey: "colorMode"); changed(layout: false) }
    }
    var style: MapStyle {
        get { MapStyle(rawValue: d.integer(forKey: "style")) ?? .cushion }
        set { d.set(newValue.rawValue, forKey: "style"); changed(layout: false) }
    }
    var labels: Bool {
        get { d.bool(forKey: "labels") }
        set { d.set(newValue, forKey: "labels"); changed(layout: false) }
    }
    var headers: Bool {
        get { d.bool(forKey: "headers") }
        set { d.set(newValue, forKey: "headers"); changed(layout: true) }
    }
    var showFree: Bool {
        get { d.bool(forKey: "showFree") }
        set { d.set(newValue, forKey: "showFree"); changed(layout: true) }
    }
    var packagesAsFiles: Bool {
        get { d.bool(forKey: "packagesAsFiles") }
        set { d.set(newValue, forKey: "packagesAsFiles"); changed(layout: true) }
    }
    var maxDepth: Int {
        get { d.integer(forKey: "maxDepth") }
        set { d.set(newValue, forKey: "maxDepth"); changed(layout: true) }
    }
    var bubble: Bool {
        get { d.bool(forKey: "bubble") }
        set { d.set(newValue, forKey: "bubble") }
    }
    var cushionHeight: Double {
        get { d.double(forKey: "cushionHeight") }
        set { d.set(newValue, forKey: "cushionHeight"); changed(layout: true) }
    }
    var cushionFalloff: Double {
        get { d.double(forKey: "cushionFalloff") }
        set { d.set(newValue, forKey: "cushionFalloff"); changed(layout: true) }
    }
    var ambient: Double {
        get { d.double(forKey: "ambient") }
        set { d.set(newValue, forKey: "ambient"); changed(layout: false) }
    }
    var brightness: Double {
        get { d.double(forKey: "brightness") }
        set { d.set(newValue, forKey: "brightness"); changed(layout: false) }
    }
    var minTile: Double {
        get { d.double(forKey: "minTile") }
        set { d.set(newValue, forKey: "minTile"); changed(layout: true) }
    }
    var excluded: [String] {
        get { d.stringArray(forKey: "excluded") ?? [] }
        set { d.set(newValue, forKey: "excluded") }
    }
    var recents: [String] {
        get { d.stringArray(forKey: "recents") ?? [] }
        set { d.set(Array(newValue.prefix(8)), forKey: "recents") }
    }
    var logical: Bool { d.bool(forKey: "logical") }
    func setLogicalFlag(_ v: Bool) { d.set(v, forKey: "logical") }
    func resetCushion() {
        for k in ["cushionHeight", "cushionFalloff", "ambient", "brightness", "minTile"] { d.removeObject(forKey: k) }
        changed(layout: true)
    }
}

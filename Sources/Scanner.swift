import Foundation

// Константы из <sys/attr.h>. Заданы явно: часть макросов импортируется в Swift с неудобными типами.
private let cmnName: UInt32 = 0x1, cmnDevID: UInt32 = 0x2, cmnObjType: UInt32 = 0x8, cmnModTime: UInt32 = 0x400
private let cmnFileID: UInt32 = 0x0200_0000, cmnError: UInt32 = 0x2000_0000, cmnReturned: UInt32 = 0x8000_0000
private let fileLinkCount: UInt32 = 0x1, fileTotalSize: UInt32 = 0x2, fileAllocSize: UInt32 = 0x4
private let vReg: UInt32 = 1, vDir: UInt32 = 2, vLnk: UInt32 = 5

struct ScanProgress {
    var files = 0, dirs = 0, denied = 0
    var bytes: Int64 = 0
    var current = ""
}

struct ScanResult {
    let root: FileNode
    let deniedPaths: [String]
    let deniedCount: Int
    let duration: TimeInterval
}

struct VolumeSpace { let total: Int64, free: Int64 }

func mountPoints() -> Set<String> {
    var out = Set<String>()
    var mp: UnsafeMutablePointer<statfs>?
    let n = getmntinfo(&mp, MNT_NOWAIT)
    guard n > 0, let m = mp else { return out }
    for i in 0..<Int(n) {
        var fs = m[i]
        let s = withUnsafeBytes(of: &fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        out.insert(s)
    }
    return out
}

func volumeSpace(_ path: String) -> VolumeSpace? {
    let url = URL(fileURLWithPath: path)
    guard let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
          let t = v.volumeTotalCapacity, let f = v.volumeAvailableCapacity else { return nil }
    return VolumeSpace(total: Int64(t), free: Int64(f))
}

/// Обновляет на корне карты плитки «Свободно» и «Не просканировано». Вызывать внутри write-блокировки.
func refreshSyntheticNodes(_ root: FileNode, isVolume: Bool) {
    root.children.removeAll { $0.isSynthetic }
    guard isVolume, let sp = volumeSpace(root.name) else { return }
    func add(_ name: String, _ kind: NodeKind, _ cat: Int, _ size: Int64) {
        guard size > 0 else { return }
        let n = FileNode(name: name, kind: kind, parent: root)
        n.alloc = size; n.logical = size; n.category = UInt8(cat)
        root.children.append(n)
    }
    add("Свободно", .free, catFree, sp.free)
    add("Не просканировано", .unknown, catUnknown, sp.total - sp.free - root.alloc)
    root.children.sort { $0.size > $1.size }
}

final class Scanner {
    private let cond = NSCondition()
    private var stack: [(FileNode, String)] = []
    private var active = 0, waiting = 0
    private var progress = ScanProgress()
    private var cancelled = false
    private var deniedPaths: [String] = []
    private var seenLinks = Set<LinkKey>()
    private var skip = Set<String>()

    private struct LinkKey: Hashable { let dev: Int32; let id: UInt64 }

    func cancel() {
        cond.lock(); cancelled = true; cond.broadcast(); cond.unlock()
    }

    func snapshot() -> ScanProgress {
        cond.lock(); defer { cond.unlock() }
        return progress
    }

    /// Блокирующий скан. Возвращает nil при отмене или если папку нельзя открыть.
    func scan(path: String, excludes: [String], threads: Int = 0) -> ScanResult? {
        let start = Date()
        guard let rp = realpath(path, nil) else { return nil }
        let rootPath = String(cString: rp)
        free(rp)

        var st = stat()
        guard lstat(rootPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }

        // Другие тома не заходим. /System/Volumes/Data тоже точка монтирования, поэтому
        // данные с него считаются один раз: через firmlink-папки вроде /Users.
        skip = mountPoints().union(excludes)
        skip.remove(rootPath)

        let root = FileNode(name: rootPath, kind: .dir, parent: nil)
        root.mtime = Int64(st.st_mtimespec.tv_sec)
        stack = [(root, rootPath)]

        let count = threads > 0 ? threads : max(4, min(12, ProcessInfo.processInfo.activeProcessorCount))
        let group = DispatchGroup()
        for _ in 0..<count {
            group.enter()
            let t = Thread { [self] in worker(); group.leave() }
            t.stackSize = 1 << 20
            t.qualityOfService = .userInitiated
            t.start()
        }
        group.wait()

        cond.lock(); let wasCancelled = cancelled; cond.unlock()
        if wasCancelled { return nil }

        Scanner.finalize(root)
        let isVolume = mountPoints().contains(rootPath)
        refreshSyntheticNodes(root, isVolume: isVolume)
        return ScanResult(root: root, deniedPaths: deniedPaths, deniedCount: progress.denied,
                          duration: Date().timeIntervalSince(start))
    }

    private func worker() {
        // Не дать сканеру выкачивать из iCloud файлы и папки, которых нет на диске.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 16)
        defer { buf.deallocate() }

        cond.lock()
        while true {
            while stack.isEmpty && active > 0 && !cancelled {
                waiting += 1; cond.wait(); waiting -= 1
            }
            if cancelled || stack.isEmpty { cond.broadcast(); break }
            let (node, path) = stack.removeLast()
            active += 1
            cond.unlock()

            var subdirs: [(FileNode, String)] = []
            var links: [(LinkKey, FileNode)] = []
            var bytes: Int64 = 0
            var files = 0
            let ok = scanDir(node, path, buf, bufSize, &subdirs, &links, &bytes, &files)

            cond.lock()
            active -= 1
            for (k, n) in links where !seenLinks.insert(k).inserted {
                bytes -= n.alloc
                n.alloc = 0; n.logical = 0
            }
            progress.files += files
            progress.dirs += 1
            progress.bytes += bytes
            progress.current = path
            if !ok {
                node.denied = true
                progress.denied += 1
                if deniedPaths.count < 1000 { deniedPaths.append(path) }
            }
            stack.append(contentsOf: subdirs)
            if waiting > 0 && (!subdirs.isEmpty || active == 0) { cond.broadcast() }
        }
        cond.unlock()
    }

    private func scanDir(_ node: FileNode, _ path: String, _ buf: UnsafeMutableRawPointer, _ bufSize: Int,
                         _ subdirs: inout [(FileNode, String)], _ links: inout [(LinkKey, FileNode)],
                         _ bytes: inout Int64, _ files: inout Int) -> Bool {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 { return false }
        defer { close(fd) }

        var al = attrlist()
        al.bitmapcount = 5
        al.commonattr = cmnReturned | cmnName | cmnError | cmnDevID | cmnObjType | cmnModTime | cmnFileID
        al.fileattr = fileLinkCount | fileTotalSize | fileAllocSize

        let prefix = path.hasSuffix("/") ? path : path + "/"
        while true {
            let n = getattrlistbulk(fd, &al, buf, bufSize, 0)
            if n < 0 { return !node.children.isEmpty }
            if n == 0 { break }
            var entry = UnsafeRawPointer(buf)
            for _ in 0..<n {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var f = entry + 4
                let rc = f.loadUnaligned(as: UInt32.self)
                let rf = (f + 12).loadUnaligned(as: UInt32.self)
                f += 20
                var err: UInt32 = 0
                if rc & cmnError != 0 { err = f.loadUnaligned(as: UInt32.self); f += 4 }
                var namePtr: UnsafePointer<UInt8>? = nil
                var nameLen = 0
                if rc & cmnName != 0 {
                    let off = f.loadUnaligned(as: Int32.self)
                    let len = f.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                    namePtr = (f + Int(off)).assumingMemoryBound(to: UInt8.self)
                    nameLen = max(0, Int(len) - 1)
                    f += 8
                }
                var dev: Int32 = 0
                if rc & cmnDevID != 0 { dev = f.loadUnaligned(as: Int32.self); f += 4 }
                var type: UInt32 = 0
                if rc & cmnObjType != 0 { type = f.loadUnaligned(as: UInt32.self); f += 4 }
                var mtime: Int64 = 0
                if rc & cmnModTime != 0 { mtime = f.loadUnaligned(as: Int64.self); f += 16 }
                var fileID: UInt64 = 0
                if rc & cmnFileID != 0 { fileID = f.loadUnaligned(as: UInt64.self); f += 8 }
                var linkCount: UInt32 = 1
                if rf & fileLinkCount != 0 { linkCount = f.loadUnaligned(as: UInt32.self); f += 4 }
                var total: Int64 = 0
                if rf & fileTotalSize != 0 { total = f.loadUnaligned(as: Int64.self); f += 8 }
                var alloc: Int64 = 0
                if rf & fileAllocSize != 0 { alloc = f.loadUnaligned(as: Int64.self); f += 8 }
                entry += length

                guard err == 0, let np = namePtr, nameLen > 0 else { continue }
                let name = String(decoding: UnsafeBufferPointer(start: np, count: nameLen), as: UTF8.self)
                let ext = extKey(np, nameLen)

                if type == vDir {
                    let childPath = prefix + name
                    if skip.contains(childPath) { continue }
                    let c = FileNode(name: name, kind: packageExts.contains(ext) ? .package : .dir, parent: node)
                    c.mtime = mtime
                    c.ext = ext
                    if c.kind == .package { c.category = UInt8(catApp) }
                    node.children.append(c)
                    subdirs.append((c, childPath))
                } else {
                    let c = FileNode(name: name, kind: type == vLnk ? .symlink : .file, parent: node)
                    c.alloc = alloc
                    c.logical = total
                    c.mtime = mtime
                    c.ext = ext
                    if ext != 0, let cat = extCategory[ext] { c.category = cat }
                    node.children.append(c)
                    files += 1
                    bytes += alloc
                    if linkCount > 1 && type == vReg {
                        links.append((LinkKey(dev: dev, id: fileID), c))
                    }
                }
            }
        }
        return true
    }

    /// Складывает размеры снизу вверх, сортирует детей и находит преобладающий тип в каждой папке.
    static func finalize(_ root: FileNode) {
        let tops = root.children.filter { $0.isFolder }
        let results = UnsafeMutablePointer<Int64>.allocate(capacity: max(1, tops.count) * catCount)
        results.initialize(repeating: 0, count: max(1, tops.count) * catCount)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: tops.count) { i in
            sum(tops[i], into: results + i * catCount)
        }
        withUnsafeTemporaryAllocation(of: Int64.self, capacity: catCount) { b in
            let acc = b.baseAddress!
            acc.initialize(repeating: 0, count: catCount)
            for i in 0..<tops.count { for c in 0..<catCount { acc[c] += results[i * catCount + c] } }
            collect(root, acc, skipFolders: true)
        }
    }

    private static func sum(_ n: FileNode, into out: UnsafeMutablePointer<Int64>) {
        withUnsafeTemporaryAllocation(of: Int64.self, capacity: catCount) { b in
            let acc = b.baseAddress!
            acc.initialize(repeating: 0, count: catCount)
            for c in n.children where c.isFolder { sum(c, into: acc) }
            collect(n, acc, skipFolders: true)
            for i in 0..<catCount { out[i] += acc[i] }
        }
    }

    private static func collect(_ n: FileNode, _ acc: UnsafeMutablePointer<Int64>, skipFolders: Bool) {
        var a: Int64 = 0, l: Int64 = 0, f: Int32 = 0, newest = n.mtime
        for c in n.children {
            a += c.alloc; l += c.logical
            if c.isFolder { f += c.fileCount } else {
                f += 1
                acc[Int(c.category)] += c.alloc
            }
            if c.mtime > newest { newest = c.mtime }
        }
        n.alloc = a; n.logical = l; n.fileCount = f; n.mtime = newest
        if n.kind == .dir {
            var best = 0; var bestV: Int64 = -1
            for i in 0..<catOther + 1 where acc[i] > bestV { best = i; bestV = acc[i] }
            n.category = UInt8(best)
        }
        n.children.sort { $0.size > $1.size }
    }
}

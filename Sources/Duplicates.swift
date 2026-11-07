import Foundation
import CryptoKit

final class DupGroup {
    let size: Int64
    var files: [FileNode]
    init(size: Int64, files: [FileNode]) { self.size = size; self.files = files }
    var wasted: Int64 { size * Int64(max(0, files.count - 1)) }
}

/// Поиск дублей: одинаковый размер, затем хеш начала и конца файла, затем SHA-256 всего файла.
final class DuplicateFinder {
    private let lock = NSLock()
    private var stop = false
    func cancel() { lock.lock(); stop = true; lock.unlock() }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stop }

    func find(in root: FileNode, minSize: Int64, progress: @escaping (String, Double) -> Void) -> [DupGroup]? {
        var bySize: [Int64: [(FileNode, String)]] = [:]
        treeLock.read {
            func walk(_ n: FileNode) {
                for c in n.children {
                    if c.isFolder { walk(c) }
                    else if c.kind == .file && c.logical >= minSize { bySize[c.logical, default: []].append((c, c.path)) }
                }
            }
            walk(root)
        }
        let candidates = bySize.filter { $0.value.count > 1 }
        let total = candidates.reduce(0) { $0 + $1.value.count }

        progress("Сравниваю начало и конец файлов", 0)
        var stage2: [[(FileNode, String)]] = []
        var done = 0
        for (size, files) in candidates {
            if isStopped { return nil }
            let groups = hashAll(files) { Self.quickHash($0, size: size) }
            stage2 += groups
            done += files.count
            progress("Сравниваю начало и конец файлов", 0.3 * Double(done) / Double(max(1, total)))
        }

        let totalBytes = stage2.reduce(Int64(0)) { $0 + $1[0].0.logical * Int64($1.count) }
        var doneBytes: Int64 = 0
        var result: [DupGroup] = []
        for files in stage2 {
            if isStopped { return nil }
            let size = files[0].0.logical
            for g in hashAll(files, Self.fullHash) { result.append(DupGroup(size: size, files: g.map { $0.0 })) }
            doneBytes += size * Int64(files.count)
            progress("Проверяю содержимое: \(fmtSize(doneBytes)) из \(fmtSize(totalBytes))",
                     0.3 + 0.7 * Double(doneBytes) / Double(max(1, totalBytes)))
        }
        if isStopped { return nil }
        return result.sorted { $0.wasted > $1.wasted }
    }

    /// Хеширует файлы параллельно и оставляет только группы из двух и более совпавших.
    private func hashAll(_ files: [(FileNode, String)], _ hash: @escaping (String) -> Data?) -> [[(FileNode, String)]] {
        var hashes = [Data?](repeating: nil, count: files.count)
        let l = NSLock()
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            if isStopped { return }
            let h = hash(files[i].1)
            l.lock(); hashes[i] = h; l.unlock()
        }
        var groups: [Data: [(FileNode, String)]] = [:]
        for (i, h) in hashes.enumerated() { if let h { groups[h, default: []].append(files[i]) } }
        return groups.values.filter { $0.count > 1 }
    }

    private static func quickHash(_ path: String, size: Int64) -> Data? {
        guard let f = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? f.close() }
        var h = SHA256()
        let part = 64 * 1024
        guard let a = try? f.read(upToCount: part) else { return nil }
        h.update(data: a)
        if size > Int64(part) * 2 {
            try? f.seek(toOffset: UInt64(size) - UInt64(part))
            if let b = try? f.read(upToCount: part) { h.update(data: b) }
        }
        return Data(h.finalize())
    }

    private static func fullHash(_ path: String) -> Data? {
        guard let f = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? f.close() }
        var h = SHA256()
        while true {
            let more: Bool = autoreleasepool {
                guard let d = try? f.read(upToCount: 4 << 20), !d.isEmpty else { return false }
                h.update(data: d)
                return true
            }
            if !more { break }
        }
        return Data(h.finalize())
    }
}

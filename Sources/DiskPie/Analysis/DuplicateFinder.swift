import CryptoKit
import Darwin
import Foundation

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

struct DupGroup: Identifiable, Sendable {
    let id = UUID()
    let size: Int64
    var paths: [String]
    var wasted: Int64 { size * Int64(max(0, paths.count - 1)) }
}

enum DuplicateFinder {
    private static let chunk = 64 * 1024

    /// Groups by size, then by a hash of the head and tail, then by a full SHA-256.
    /// Hard links (same inode) are not duplicates and are folded together first.
    static func find(_ files: [(path: String, size: Int64)], cancel: CancelFlag,
                     progress: @escaping @Sendable (String, Double) -> Void) -> [DupGroup] {
        var bySize: [Int64: [String]] = [:]
        for file in files { bySize[file.size, default: []].append(file.path) }
        let candidates = bySize.filter { $0.value.count > 1 }.sorted { $0.key > $1.key }
        var groups: [DupGroup] = []

        for (index, (size, paths)) in candidates.enumerated() {
            if cancel.isCancelled { break }
            if index % 8 == 0 {
                progress("Сравниваю файлы по \(Fmt.size(size))", Double(index) / Double(max(1, candidates.count)))
            }
            let unique = uniqueInodes(paths)
            guard unique.count > 1 else { continue }

            var byPartial: [Data: [String]] = [:]
            for path in unique {
                if let hash = partialHash(path, size: size) { byPartial[hash, default: []].append(path) }
            }
            for sameHead in byPartial.values where sameHead.count > 1 {
                if size <= Int64(chunk * 2) {
                    groups.append(DupGroup(size: size, paths: sameHead.sorted()))
                    continue
                }
                var byFull: [Data: [String]] = [:]
                for path in sameHead {
                    if cancel.isCancelled { break }
                    if let hash = fullHash(path) { byFull[hash, default: []].append(path) }
                }
                for same in byFull.values where same.count > 1 {
                    groups.append(DupGroup(size: size, paths: same.sorted()))
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    private static func uniqueInodes(_ paths: [String]) -> [String] {
        var seen = Set<UInt64>()
        var dev: Int32 = -1
        var result: [String] = []
        for path in paths {
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            let key = UInt64(st.st_ino) ^ (UInt64(UInt32(bitPattern: st.st_dev)) << 48)
            if dev == -1 { dev = st.st_dev }
            if seen.insert(key).inserted { result.append(path) }
        }
        return result
    }

    private static func partialHash(_ path: String, size: Int64) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: chunk) else { return nil }
        hasher.update(data: head)
        if size > Int64(chunk * 2) {
            try? handle.seek(toOffset: UInt64(size) - UInt64(chunk))
            if let tail = try? handle.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return Data(hasher.finalize())
    }

    private static func fullHash(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let data = try? handle.read(upToCount: 1 << 20) else { return nil }
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return Data(hasher.finalize())
    }
}

@MainActor @Observable
final class DuplicateSearch {
    enum Phase { case idle, running, done }

    var phase: Phase = .idle
    var status = ""
    var fraction = 0.0
    var groups: [DupGroup] = []
    var minSize: Int64 = 1_000_000
    var scopePath = ""
    @ObservationIgnored private var flag = CancelFlag()

    var totalWasted: Int64 { groups.reduce(0) { $0 + $1.wasted } }

    func start(in node: FileNode) {
        cancel()
        let min = minSize
        var files: [(path: String, size: Int64)] = []
        Analyses.walk(node) { n in
            if n.kind == .file, n.size >= min { files.append((n.path, n.size)) }
        }
        scopePath = node.path
        groups = []
        phase = .running
        fraction = 0
        status = "Файлов-кандидатов: \(Fmt.count(files.count))"
        let flag = CancelFlag()
        self.flag = flag
        Task.detached(priority: .utility) { [self] in
            let result = DuplicateFinder.find(files, cancel: flag) { text, value in
                Task { @MainActor in
                    guard !flag.isCancelled else { return }
                    self.status = text
                    self.fraction = value
                }
            }
            await MainActor.run {
                guard !flag.isCancelled else { return }
                self.groups = result
                self.phase = .done
                self.fraction = 1
            }
        }
    }

    func cancel() {
        flag.cancel()
        if phase == .running { phase = .idle }
    }

    func forget(paths: [String]) {
        let removed = Set(paths)
        groups = groups.compactMap { group in
            var g = group
            g.paths.removeAll { removed.contains($0) }
            return g.paths.count > 1 ? g : nil
        }
    }
}

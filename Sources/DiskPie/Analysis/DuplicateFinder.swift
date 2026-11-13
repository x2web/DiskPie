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
    /// Disk space taken by one copy.
    let size: Int64
    /// SHA-256 of the full contents.
    let hash: Data
    var paths: [String]
    var wasted: Int64 { size * Int64(max(0, paths.count - 1)) }
}

enum DuplicateFinder {
    private static let chunk = 64 * 1024

    /// Groups by allocated size, then by exact length, then by a hash of the head and tail, then by a full
    /// SHA-256. Hard links (same inode) are not duplicates and are folded together first.
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
            var byLength: [Int64: [String]] = [:]
            for (path, length) in uniqueInodes(paths) { byLength[length, default: []].append(path) }

            for (length, sameLength) in byLength where sameLength.count > 1 {
                var byPartial: [Data: [String]] = [:]
                for path in sameLength {
                    if let hash = partialHash(path, length: length) { byPartial[hash, default: []].append(path) }
                }
                for sameHead in byPartial.values where sameHead.count > 1 {
                    if cancel.isCancelled { break }
                    // The head hash already covers files that fit in one chunk.
                    if length <= Int64(chunk), let hash = fullHash(sameHead[0]) {
                        groups.append(DupGroup(size: size, hash: hash, paths: sameHead.sorted()))
                        continue
                    }
                    var byFull: [Data: [String]] = [:]
                    for path in sameHead {
                        if cancel.isCancelled { break }
                        if let hash = fullHash(path) { byFull[hash, default: []].append(path) }
                    }
                    for (hash, same) in byFull where same.count > 1 {
                        groups.append(DupGroup(size: size, hash: hash, paths: same.sorted()))
                    }
                }
            }
        }
        return groups.sorted { $0.wasted > $1.wasted }
    }

    /// Distinct regular files with their exact length.
    private static func uniqueInodes(_ paths: [String]) -> [(String, Int64)] {
        var seen = Set<[UInt64]>()
        var result: [(String, Int64)] = []
        for path in paths {
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            if seen.insert([UInt64(UInt32(bitPattern: st.st_dev)), st.st_ino]).inserted {
                result.append((path, Int64(st.st_size)))
            }
        }
        return result
    }

    private static func partialHash(_ path: String, length: Int64) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        guard let head = try? handle.read(upToCount: chunk) else { return nil }
        hasher.update(data: head)
        if length > Int64(chunk) {
            try? handle.seek(toOffset: UInt64(length) - UInt64(chunk))
            if let tail = try? handle.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return Data(hasher.finalize())
    }

    static func fullHash(_ path: String) -> Data? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // read(upToCount:) returns nil at end of file.
            while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            return nil
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

    /// Copies other than the first that still match the first byte for byte; empty when the first copy
    /// is gone or changed, so the last remaining copy is never removed.
    func extraCopies(in group: DupGroup) -> [String] {
        guard let first = group.paths.first, DuplicateFinder.fullHash(first) == group.hash else { return [] }
        return group.paths.dropFirst().filter { DuplicateFinder.fullHash($0) == group.hash }
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

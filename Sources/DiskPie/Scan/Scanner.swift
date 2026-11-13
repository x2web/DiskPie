import Darwin
import Foundation

struct DeniedPath: Sendable, Hashable {
    let path: String
    let code: Int32
}

struct ScanProgress: Sendable {
    var files = 0
    var dirs = 0
    var bytes: Int64 = 0
    var inaccessible = 0
    var current = ""
}

private struct HardLinkKey: Hashable {
    let dev: Int32
    let ino: UInt64
}

/// Hard-linked inodes already counted, with the path that owns the count. Shared between the full scan
/// and later rescans, so a rescan of the owning folder keeps the size and other links stay at zero.
final class HardLinkRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var owners: [HardLinkKey: String] = [:]

    func claim(dev: Int32, ino: UInt64, path: String) -> Bool {
        lock.withLock {
            let key = HardLinkKey(dev: dev, ino: ino)
            if let owner = owners[key] { return owner == path }
            owners[key] = path
            return true
        }
    }
}

final class ScanContext: @unchecked Sendable {
    let skipPaths: Set<String>
    private let lock = NSLock()
    private var progress = ScanProgress()
    private var cancelled = false
    private var denied: [DeniedPath] = []
    let links: HardLinkRegistry
    static let deniedLimit = 5000

    init(skipPaths: Set<String>, links: HardLinkRegistry = HardLinkRegistry()) {
        self.skipPaths = skipPaths
        self.links = links
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }

    /// Returns true when the scan was cancelled.
    func report(files: Int, dirs: Int, bytes: Int64, inaccessible: Int, current: String?) -> Bool {
        lock.withLock {
            progress.files += files
            progress.dirs += dirs
            progress.bytes += bytes
            progress.inaccessible += inaccessible
            if let current { progress.current = current }
            return cancelled
        }
    }

    func recordDenied(_ path: String, code: Int32) {
        lock.withLock {
            if denied.count < Self.deniedLimit { denied.append(DeniedPath(path: path, code: code)) }
        }
    }

    var deniedPaths: [DeniedPath] {
        lock.withLock { denied }
    }

    func snapshot() -> ScanProgress {
        lock.withLock { progress }
    }
}

enum Scanner {
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "prefpane", "qlgenerator",
        "mdimporter", "saver", "xcarchive", "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary",
        "imovielibrary", "fcpbundle", "logicx", "sparsebundle", "utm", "pkg", "mpkg", "rtfd",
        "playground", "xcodeproj", "xcworkspace", "doccarchive", "dsym", "band", "pages", "numbers", "key",
    ]

    static func isPackage(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return packageExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// Walks `path` with fts. In shallow mode subdirectories are returned as empty pending nodes.
    static func scan(path: String, shallow: Bool, ctx: ScanContext) -> FileNode {
        var root: FileNode?
        var stack: [FileNode] = []
        var levels: [Int] = []
        var files = 0, dirs = 0, inaccessible = 0
        var bytes: Int64 = 0
        var tick = 0

        guard let cPath = strdup(path) else { return FileNode(name: path, kind: .inaccessible) }
        defer { free(cPath) }
        let argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            return FileNode(name: path, kind: .inaccessible)
        }
        defer { fts_close(fts) }

        func attach(_ node: FileNode, level: Int) {
            if level == 0 || stack.isEmpty {
                root = node
            } else {
                let parent = stack[stack.count - 1]
                node.parent = parent
                parent.children.append(node)
            }
        }

        while let entry = fts_read(fts) {
            let e = entry.pointee
            let level = Int(e.fts_level)
            let info = Int32(e.fts_info)

            switch info {
            case FTS_D:
                if level > 0, !ctx.skipPaths.isEmpty, ctx.skipPaths.contains(String(cString: e.fts_path)) {
                    fts_set(fts, entry, FTS_SKIP)
                    continue
                }
                let name = level == 0 ? path : entryName(e)
                let node = FileNode(name: name, kind: isPackage(name) ? .package : .directory)
                if let st = e.fts_statp { setDates(node, st.pointee) }
                attach(node, level: level)
                dirs += 1
                if shallow && level >= 1 {
                    node.isPending = true
                    fts_set(fts, entry, FTS_SKIP)
                } else {
                    stack.append(node)
                    levels.append(level)
                }

            case FTS_DP:
                if levels.last == level {
                    levels.removeLast()
                    stack.removeLast().finalizeDirectory()
                }

            case FTS_DNR, FTS_ERR:
                inaccessible += 1
                ctx.recordDenied(String(cString: e.fts_path), code: e.fts_errno)
                if levels.last == level {
                    levels.removeLast()
                    let node = stack.removeLast()
                    node.kind = .inaccessible
                    node.finalizeDirectory()
                } else {
                    attach(FileNode(name: level == 0 ? path : entryName(e), kind: .inaccessible), level: level)
                }

            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let statp = e.fts_statp else { continue }
                let st = statp.pointee
                var allocated = Int64(st.st_blocks) * 512
                if st.st_nlink > 1, !ctx.links.claim(dev: st.st_dev, ino: st.st_ino, path: String(cString: e.fts_path)) {
                    allocated = 0
                }
                let kind: NodeKind = (info == FTS_SL || info == FTS_SLNONE) ? .symlink : .file
                let node = FileNode(name: level == 0 ? path : entryName(e), kind: kind, size: allocated, fileCount: 1)
                setDates(node, st)
                attach(node, level: level)
                files += 1
                bytes += allocated

            default:
                continue
            }

            tick += 1
            if tick & 0x7FF == 0 {
                let cancelled = ctx.report(files: files, dirs: dirs, bytes: bytes, inaccessible: inaccessible,
                                           current: String(cString: e.fts_path))
                files = 0; dirs = 0; bytes = 0; inaccessible = 0
                if cancelled { break }
            }
        }

        _ = ctx.report(files: files, dirs: dirs, bytes: bytes, inaccessible: inaccessible, current: nil)
        while let node = stack.popLast() { node.finalizeDirectory() }
        return root ?? FileNode(name: path, kind: .inaccessible)
    }

    private static func entryName(_ e: FTSENT) -> String {
        let offset = Int(e.fts_pathlen) - Int(e.fts_namelen)
        return String(cString: e.fts_path + offset)
    }

    private static func setDates(_ node: FileNode, _ st: stat) {
        node.modified = Double(st.st_mtimespec.tv_sec)
        node.accessed = Double(st.st_atimespec.tv_sec)
    }
}

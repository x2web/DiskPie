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
    /// Cloud placeholders (iCloud Drive, File Provider) that were not downloaded.
    var cloudFiles = 0
    var cloudFolders = 0
    var cloudBytes: Int64 = 0
    /// Bytes not counted because clones share them with a file counted earlier.
    var cloneBytes: Int64 = 0
    var current = ""
}

private struct SharedKey: Hashable {
    let dev: Int32
    let id: UInt64
}

/// Data shared between files: hard-linked inodes and APFS clones. The first path that claims a shared
/// inode or clone owns its size; the registry outlives the full scan, so a rescan of the owning folder
/// keeps the size and the other copies stay at their private size.
final class SharedDataRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var links: [SharedKey: String] = [:]
    private var clones: [SharedKey: String] = [:]
    /// Count data shared by APFS clones once. Costs one extra call per file.
    let countsClones: Bool

    init(countsClones: Bool = ScanSettings.countsClones) {
        self.countsClones = countsClones
    }

    func claimLink(dev: Int32, ino: UInt64, path: String) -> Bool {
        lock.withLock { Self.claim(&links, SharedKey(dev: dev, id: ino), path) }
    }

    func claimClone(dev: Int32, cloneID: UInt64, path: String) -> Bool {
        lock.withLock { Self.claim(&clones, SharedKey(dev: dev, id: cloneID), path) }
    }

    private static func claim(_ owners: inout [SharedKey: String], _ key: SharedKey, _ path: String) -> Bool {
        if let owner = owners[key] { return owner == path }
        owners[key] = path
        return true
    }
}

enum ScanSettings {
    static let countsClonesKey = "countClonesOnce"

    static var countsClones: Bool {
        // bool(forKey:) also parses "NO" given as a launch argument (-countClonesOnce NO).
        UserDefaults.standard.object(forKey: countsClonesKey) == nil || UserDefaults.standard.bool(forKey: countsClonesKey)
    }
}

final class ScanContext: @unchecked Sendable {
    let skipPaths: Set<String>
    private let lock = NSLock()
    private var progress = ScanProgress()
    private var cancelled = false
    private var denied: [DeniedPath] = []
    let links: SharedDataRegistry
    static let deniedLimit = 5000

    init(skipPaths: Set<String>, links: SharedDataRegistry = SharedDataRegistry()) {
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
    /// Scanned folders waiting to be attached to the tree on the main actor, in completion order.
    private var results: [(placeholder: FileNode, scanned: FileNode)] = []

    func deliver(_ placeholder: FileNode, _ scanned: FileNode) {
        lock.withLock { results.append((placeholder, scanned)) }
    }

    func takeResults() -> [(placeholder: FileNode, scanned: FileNode)] {
        lock.withLock {
            defer { results.removeAll(keepingCapacity: true) }
            return results
        }
    }

    func addCloud(files: Int, folders: Int, bytes: Int64) {
        lock.withLock {
            progress.cloudFiles += files
            progress.cloudFolders += folders
            progress.cloudBytes += bytes
        }
    }

    func report(files: Int, dirs: Int, bytes: Int64, cloneBytes: Int64, inaccessible: Int, current: String?) -> Bool {
        lock.withLock {
            progress.files += files
            progress.dirs += dirs
            progress.bytes += bytes
            progress.cloneBytes += cloneBytes
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
        var bytes: Int64 = 0, cloneBytes: Int64 = 0
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
                // A folder the File Provider has not listed yet: reading it would fetch it from the cloud.
                if level > 0, let st = e.fts_statp, isDataless(st.pointee) {
                    let node = FileNode(name: entryName(e), kind: .directory)
                    node.isCloud = true
                    setDates(node, st.pointee)
                    attach(node, level: level)
                    ctx.addCloud(files: 0, folders: 1, bytes: 0)
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
                if st.st_nlink > 1, !ctx.links.claimLink(dev: st.st_dev, ino: st.st_ino, path: String(cString: e.fts_path)) {
                    allocated = 0
                }
                if info == FTS_F, allocated > 0, ctx.links.countsClones, !isDataless(st),
                   let clone = cloneInfo(e.fts_path), clone.privateSize < allocated,
                   !ctx.links.claimClone(dev: st.st_dev, cloneID: clone.id, path: String(cString: e.fts_path)) {
                    cloneBytes += allocated - clone.privateSize
                    allocated = clone.privateSize
                }
                let kind: NodeKind = (info == FTS_SL || info == FTS_SLNONE) ? .symlink : .file
                let node = FileNode(name: level == 0 ? path : entryName(e), kind: kind, size: allocated, fileCount: 1)
                setDates(node, st)
                if isDataless(st) {
                    node.isCloud = true
                    ctx.addCloud(files: 1, folders: 0, bytes: Int64(st.st_size))
                }
                attach(node, level: level)
                files += 1
                bytes += allocated

            default:
                continue
            }

            tick += 1
            if tick & 0x7FF == 0 {
                let cancelled = ctx.report(files: files, dirs: dirs, bytes: bytes, cloneBytes: cloneBytes,
                                           inaccessible: inaccessible, current: String(cString: e.fts_path))
                files = 0; dirs = 0; bytes = 0; cloneBytes = 0; inaccessible = 0
                if cancelled { break }
            }
        }

        _ = ctx.report(files: files, dirs: dirs, bytes: bytes, cloneBytes: cloneBytes, inaccessible: inaccessible, current: nil)
        while let node = stack.popLast() { node.finalizeDirectory() }
        return root ?? FileNode(name: path, kind: .inaccessible)
    }

    private static func entryName(_ e: FTSENT) -> String {
        let offset = Int(e.fts_pathlen) - Int(e.fts_namelen)
        return String(cString: e.fts_path + offset)
    }

    /// APFS clone family of a file and the part of its blocks that no other clone shares.
    /// Files copied with clonefile keep one clone ID until one of them is written to.
    private static func cloneInfo(_ path: UnsafePointer<CChar>) -> (id: UInt64, privateSize: Int64)? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID)
        // u_int32_t length, then attributes in bit order: private size (off_t), clone ID (u_int64_t).
        var buffer = (UInt32(0), Int64(0), UInt64(0))
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
        let result = withUnsafeMutableBytes(of: &buffer) { raw -> (UInt64, Int64)? in
            guard getattrlist(path, &request, raw.baseAddress, raw.count, options) == 0 else { return nil }
            return (raw.loadUnaligned(fromByteOffset: 12, as: UInt64.self), raw.loadUnaligned(fromByteOffset: 4, as: Int64.self))
        }
        guard let result, result.0 != 0 else { return nil }
        return (result.0, result.1)
    }

    /// Cloud-only placeholder: metadata is local, contents are not.
    private static func isDataless(_ st: stat) -> Bool {
        st.st_flags & UInt32(SF_DATALESS) != 0
    }

    /// Makes reads of cloud-only files fail instead of downloading them, for the whole process.
    static func disableCloudDownloads() {
        _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
    }

    private static func setDates(_ node: FileNode, _ st: stat) {
        node.modified = Double(st.st_mtimespec.tv_sec)
        node.accessed = Double(st.st_atimespec.tv_sec)
    }
}

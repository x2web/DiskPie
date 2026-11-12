import Foundation

enum ArchiveError: Error { case corrupt, unsupported }

/// Compact binary snapshot of a scanned tree, compressed with LZFSE.
enum ScanArchive {
    private static let magic: UInt32 = 0x3153_5044 // "DPS1"

    struct Header {
        let rootPath: String
        let date: Date
        let partial: Bool
    }

    static func encode(_ root: FileNode, rootPath: String, date: Date, partial: Bool) throws -> Data {
        var w = BinWriter()
        w.buf.reserveCapacity(max(1 << 16, root.fileCount * 48))
        w.u32(magic)
        w.str(rootPath)
        w.f64(date.timeIntervalSince1970)
        w.u8(partial ? 1 : 0)
        write(root, &w)
        return try (Data(w.buf) as NSData).compressed(using: .lzfse) as Data
    }

    private static func write(_ node: FileNode, _ w: inout BinWriter) {
        w.u8(node.kind.rawValue)
        w.u8(node.isPending ? 1 : 0)
        w.i64(node.size)
        w.i64(Int64(node.fileCount))
        w.f64(node.modified)
        w.f64(node.accessed)
        w.str(node.name)
        w.u32(UInt32(node.children.count))
        for child in node.children { write(child, &w) }
    }

    static func decode(_ data: Data) throws -> (Header, FileNode) {
        let raw = try (data as NSData).decompressed(using: .lzfse) as Data
        return try raw.withUnsafeBytes { buffer in
            var r = BinReader(buf: buffer)
            guard try r.u32() == magic else { throw ArchiveError.unsupported }
            let header = Header(rootPath: try r.str(), date: Date(timeIntervalSince1970: try r.f64()), partial: try r.u8() != 0)
            let root = try read(&r, depth: 0)
            return (header, root)
        }
    }

    private static func read(_ r: inout BinReader, depth: Int) throws -> FileNode {
        guard depth < 4096, let kind = NodeKind(rawValue: try r.u8()) else { throw ArchiveError.corrupt }
        let pending = try r.u8() != 0
        let size = try r.i64()
        let count = Int(try r.i64())
        let modified = try r.f64()
        let accessed = try r.f64()
        let node = FileNode(name: try r.str(), kind: kind, size: size, fileCount: count, modified: modified, accessed: accessed)
        node.isPending = pending
        let childCount = Int(try r.u32())
        if childCount > 0 {
            node.children.reserveCapacity(childCount)
            for _ in 0..<childCount {
                let child = try read(&r, depth: depth + 1)
                child.parent = node
                node.children.append(child)
            }
        }
        return node
    }
}

private struct BinWriter {
    var buf: [UInt8] = []

    mutating func u8(_ v: UInt8) { buf.append(v) }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { buf.append(contentsOf: $0) } }
    mutating func i64(_ v: Int64) { withUnsafeBytes(of: v.littleEndian) { buf.append(contentsOf: $0) } }
    mutating func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { buf.append(contentsOf: $0) } }
    mutating func str(_ s: String) {
        let utf8 = s.utf8
        u32(UInt32(utf8.count))
        buf.append(contentsOf: utf8)
    }
}

private struct BinReader {
    let buf: UnsafeRawBufferPointer
    var pos = 0

    private mutating func take(_ n: Int) throws -> Int {
        guard n >= 0, pos + n <= buf.count else { throw ArchiveError.corrupt }
        defer { pos += n }
        return pos
    }

    mutating func u8() throws -> UInt8 { buf[try take(1)] }
    mutating func u32() throws -> UInt32 { UInt32(littleEndian: buf.loadUnaligned(fromByteOffset: try take(4), as: UInt32.self)) }
    mutating func i64() throws -> Int64 { Int64(littleEndian: buf.loadUnaligned(fromByteOffset: try take(8), as: Int64.self)) }
    mutating func f64() throws -> Double {
        Double(bitPattern: UInt64(littleEndian: buf.loadUnaligned(fromByteOffset: try take(8), as: UInt64.self)))
    }
    mutating func str() throws -> String {
        let length = Int(try u32())
        let start = try take(length)
        return String(decoding: UnsafeRawBufferPointer(rebasing: buf[start..<start + length]), as: UTF8.self)
    }
}

struct ScanMeta: Codable, Identifiable, Hashable {
    var id: String { file }
    let rootPath: String
    let date: Date
    let totalSize: Int64
    let fileCount: Int
    let file: String
    let partial: Bool
}

/// Keeps the last few snapshots per scanned folder in Application Support.
enum ScanStore {
    static let keepPerRoot = 6

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskPie/Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @discardableResult
    static func save(_ root: FileNode, rootPath: String, date: Date, partial: Bool) throws -> ScanMeta {
        let data = try ScanArchive.encode(root, rootPath: rootPath, date: date, partial: partial)
        let stem = "\(slug(rootPath))-\(Int(date.timeIntervalSince1970))"
        let meta = ScanMeta(rootPath: rootPath, date: date, totalSize: root.size, fileCount: root.fileCount,
                            file: stem + ".dpscan", partial: partial)
        try data.write(to: directory.appendingPathComponent(meta.file), options: .atomic)
        try JSONEncoder().encode(meta).write(to: directory.appendingPathComponent(stem + ".json"), options: .atomic)
        prune(rootPath: rootPath)
        return meta
    }

    static func all() -> [ScanMeta] {
        let dir = directory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }
            .compactMap { try? JSONDecoder().decode(ScanMeta.self, from: Data(contentsOf: dir.appendingPathComponent($0))) }
            .sorted { $0.date > $1.date }
    }

    static func load(_ meta: ScanMeta) throws -> FileNode {
        try ScanArchive.decode(Data(contentsOf: directory.appendingPathComponent(meta.file))).1
    }

    static func delete(_ meta: ScanMeta) {
        let dir = directory
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(meta.file))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent((meta.file as NSString).deletingPathExtension + ".json"))
    }

    static func deleteAll() {
        all().forEach(delete)
    }

    static var diskUsage: Int64 {
        let dir = directory
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.reduce(0) { total, name in
            let attributes = try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name).path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    private static func prune(rootPath: String) {
        all().filter { $0.rootPath == rootPath }.dropFirst(keepPerRoot).forEach(delete)
    }

    private static func slug(_ path: String) -> String {
        var hash: UInt64 = 5381
        for byte in path.utf8 { hash = (hash &* 33) ^ UInt64(byte) }
        let readable = path.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined().prefix(48)
        return "\(readable)-\(String(hash, radix: 16))"
    }
}

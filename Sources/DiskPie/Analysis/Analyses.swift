import Foundation

/// Bounded list of the largest items, kept in descending order.
struct TopK<T> {
    let limit: Int
    private(set) var items: [(size: Int64, value: T)] = []

    init(limit: Int) { self.limit = limit }

    mutating func insert(_ size: Int64, _ value: T) {
        if items.count >= limit, let last = items.last, size <= last.size { return }
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].size >= size { lo = mid + 1 } else { hi = mid }
        }
        items.insert((size, value), at: lo)
        if items.count > limit { items.removeLast() }
    }
}

struct ResultRow: Identifiable {
    let id: ObjectIdentifier
    let ref: WeakNode
    let name: String
    let size: Int64
    let detail: String

    init(_ node: FileNode, detail: String? = nil) {
        id = node.id
        ref = WeakNode(node)
        name = node.name
        size = node.size
        self.detail = detail ?? (node.parent?.path ?? node.path)
    }
}

struct CategoryStat: Identifiable {
    var id: FileCategory { category }
    let category: FileCategory
    var size: Int64 = 0
    var count = 0
    var top = TopK<FileNode>(limit: 100)
}

enum Analyses {
    static func walk(_ root: FileNode, descend: (FileNode) -> Bool = { _ in true }, _ visit: (FileNode) -> Void) {
        var stack = [root]
        while let node = stack.popLast() {
            visit(node)
            if node.isContainer, descend(node) { stack.append(contentsOf: node.children) }
        }
    }

    static func largestFiles(in root: FileNode, limit: Int = 300) -> [FileNode] {
        var top = TopK<FileNode>(limit: limit)
        walk(root) { node in
            if node.isFileLike || node.kind == .package { top.insert(node.size, node) }
        }
        return top.items.map(\.value)
    }

    static func largestFolders(in root: FileNode, limit: Int = 100) -> [FileNode] {
        var top = TopK<FileNode>(limit: limit)
        walk(root) { node in
            if node.kind == .directory, node !== root { top.insert(node.size, node) }
        }
        return top.items.map(\.value)
    }

    /// Packages count as one item of the "apps" category and are not opened.
    static func categories(in root: FileNode) -> [CategoryStat] {
        var stats: [FileCategory: CategoryStat] = [:]
        walk(root, descend: { $0.kind != .package || $0 === root }) { node in
            guard node.isFileLike || (node.kind == .package && node !== root) else { return }
            let category = FileCategory.of(node)
            var stat = stats[category] ?? CategoryStat(category: category)
            stat.size += node.size
            stat.count += 1
            stat.top.insert(node.size, node)
            stats[category] = stat
        }
        return stats.values.sorted { $0.size > $1.size }
    }

    static func oldFiles(in root: FileNode, olderThan cutoff: Date, limit: Int = 300) -> (files: [FileNode], total: Int64, count: Int) {
        let threshold = cutoff.timeIntervalSince1970
        var top = TopK<FileNode>(limit: limit)
        var total: Int64 = 0
        var count = 0
        walk(root) { node in
            guard node.isFileLike, node.modified > 0, max(node.modified, node.accessed) < threshold else { return }
            top.insert(node.size, node)
            total += node.size
            count += 1
        }
        return (top.items.map(\.value), total, count)
    }

    static let buildArtifactNames: Set<String> = [
        "node_modules", "Pods", ".build", "DerivedData", "build", ".gradle", "target", "__pycache__",
        ".venv", "venv", ".next", ".nuxt", "dist", ".parcel-cache", ".turbo", "Carthage", ".dart_tool", ".cxx",
    ]

    /// Dependency and build folders inside projects; nested matches are folded into the outer one.
    static func buildArtifacts(in root: FileNode, limit: Int = 200) -> [FileNode] {
        var top = TopK<FileNode>(limit: limit)
        walk(root, descend: { node in
            if node !== root && buildArtifactNames.contains(node.name) {
                top.insert(node.size, node)
                return false
            }
            return true
        }) { _ in }
        return top.items.map(\.value).filter { $0.size > 0 }
    }
}

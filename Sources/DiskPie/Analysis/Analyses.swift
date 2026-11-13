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

    /// App bundles and other packages count as single items and are not opened.
    static func largestFiles(in root: FileNode, limit: Int = 300) -> [FileNode] {
        var top = TopK<FileNode>(limit: limit)
        walk(root, descend: { $0.kind != .package || $0 === root }) { node in
            if node.isFileLike || (node.kind == .package && node !== root) { top.insert(node.size, node) }
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

struct ChangeItem: Identifiable {
    var id: String { path }
    let path: String
    let oldSize: Int64
    let newSize: Int64
    let isDirectory: Bool
    var delta: Int64 { newSize - oldSize }
    var isNew: Bool { oldSize == 0 && newSize > 0 }
    var isGone: Bool { newSize == 0 && oldSize > 0 }
}

extension Analyses {
    /// Compares two snapshots of the same root. A folder is reported only when its change is spread
    /// over children; otherwise the change is attributed to the child that caused it.
    static func changes(current: FileNode, previous: FileNode, rootPath: String, threshold: Int64, limit: Int = 300) -> [ChangeItem] {
        var result: [ChangeItem] = []

        func join(_ base: String, _ name: String) -> String {
            base.hasSuffix("/") ? base + name : base + "/" + name
        }

        @discardableResult
        func compare(_ new: FileNode?, _ old: FileNode?, path: String) -> Int64 {
            let newSize = new?.size ?? 0
            let oldSize = old?.size ?? 0
            let delta = newSize - oldSize
            guard abs(delta) >= threshold else { return delta }
            let isDirectory = (new ?? old)?.isContainer ?? false

            var maxChild: Int64 = 0
            if isDirectory, new?.kind != .hidden {
                var oldChildren: [String: FileNode] = [:]
                for child in old?.children ?? [] { oldChildren[child.name] = child }
                for child in new?.children ?? [] {
                    let childDelta = compare(child, oldChildren.removeValue(forKey: child.name), path: join(path, child.name))
                    maxChild = max(maxChild, abs(childDelta))
                }
                for child in oldChildren.values {
                    let childDelta = compare(nil, child, path: join(path, child.name))
                    maxChild = max(maxChild, abs(childDelta))
                }
            }
            if !isDirectory || Double(maxChild) < Double(abs(delta)) * 0.75 || new == nil || old == nil {
                result.append(ChangeItem(path: path, oldSize: oldSize, newSize: newSize, isDirectory: isDirectory))
            }
            return delta
        }

        compare(current, previous, path: rootPath)
        return Array(result.filter { $0.path != rootPath }.sorted { abs($0.delta) > abs($1.delta) }.prefix(limit))
    }
}

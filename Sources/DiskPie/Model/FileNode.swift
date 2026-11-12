import Foundation

enum NodeKind: UInt8 {
    case file, directory, package, symlink, inaccessible, hidden
}

/// Tree node. The tree is mutated only on the main actor once it is installed in `AppModel`;
/// background scanners build detached subtrees and hand them over.
final class FileNode: Identifiable, @unchecked Sendable {
    var name: String
    var size: Int64
    var fileCount: Int
    var kind: NodeKind
    var isPending = false
    var modified: Double
    var accessed: Double
    var children: [FileNode] = []
    // Children own their parent strongly through `children`; async work refers to nodes by path,
    // and every removal goes through AppModel.sanitize, so no stale node outlives its parent.
    unowned(unsafe) var parent: FileNode?

    init(name: String, kind: NodeKind, size: Int64 = 0, fileCount: Int = 0, modified: Double = 0, accessed: Double = 0) {
        self.name = name
        self.kind = kind
        self.size = size
        self.fileCount = fileCount
        self.modified = modified
        self.accessed = accessed
    }

    var id: ObjectIdentifier { ObjectIdentifier(self) }
    var isContainer: Bool { kind == .directory || kind == .package }
    var isFileLike: Bool { kind == .file || kind == .symlink }
    var isActionable: Bool { kind != .hidden && parent != nil }
    var isRoot: Bool { parent == nil }

    var path: String {
        var components: [String] = []
        var node = self
        while let parent = node.parent {
            components.append(node.name)
            node = parent
        }
        let rootPath = node.name
        if components.isEmpty { return rootPath }
        let base = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return base + components.reversed().joined(separator: "/")
    }

    var url: URL { URL(fileURLWithPath: path, isDirectory: isContainer) }

    var displayName: String {
        guard parent == nil else { return name }
        if name == "/" { return DiskAccess.volumeName(for: "/") ?? "/" }
        return (name as NSString).lastPathComponent
    }

    var fileExtension: String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// Root first, self last.
    var ancestors: [FileNode] {
        var result: [FileNode] = []
        var node: FileNode? = self
        while let current = node {
            result.append(current)
            node = current.parent
        }
        return result.reversed()
    }

    var root: FileNode {
        var node = self
        while let parent = node.parent { node = parent }
        return node
    }

    func isDescendant(of other: FileNode) -> Bool {
        var node: FileNode? = self
        while let current = node {
            if current === other { return true }
            node = current.parent
        }
        return false
    }

    func child(named name: some StringProtocol) -> FileNode? {
        children.first { $0.name == name }
    }

    func sortChildren() {
        children.sort { $0.size > $1.size }
    }

    func adopt(_ newChildren: [FileNode]) {
        children = newChildren
        for child in children { child.parent = self }
    }

    func finalizeDirectory() {
        var total: Int64 = 0
        var count = 0
        for child in children {
            total += child.size
            count += child.fileCount
        }
        size = total
        fileCount = count
        sortChildren()
    }

    /// Adds deltas to self and all ancestors, keeping every level sorted by size.
    func applyDelta(size sizeDelta: Int64, count countDelta: Int) {
        guard sizeDelta != 0 || countDelta != 0 else { return }
        var node: FileNode? = self
        while let current = node {
            current.size += sizeDelta
            current.fileCount += countDelta
            current.parent?.sortChildren()
            node = current.parent
        }
    }

    func pendingChildren(basePath: String) -> [(FileNode, String)] {
        let base = basePath.hasSuffix("/") ? basePath : basePath + "/"
        return children.filter(\.isPending).map { ($0, base + $0.name) }
    }
}

/// Holds a node without keeping it alive: results of analyses must not outlive tree removals.
struct WeakNode {
    weak var node: FileNode?
    init(_ node: FileNode) { self.node = node }
}

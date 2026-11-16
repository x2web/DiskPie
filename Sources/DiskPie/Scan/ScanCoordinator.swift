import Foundation

/// Progressive parallel scan, breadth first. Folders near the root are read one level at a time, so
/// each appears in the tree as soon as it is listed and its subfolders fill in as they are read.
/// Below `expandDepth` a branch is scanned in one pass. Results are attached by the main actor in
/// batches (see AppModel.applyScanResults).
enum ScanCoordinator {
    static let expandDepth = 6

    private struct Unit: Sendable {
        let placeholder: FileNode
        let path: String
        let depth: Int
    }

    static func run(path: String, ctx: ScanContext, model: AppModel) async {
        let root = Scanner.scan(path: path, shallow: true, ctx: ctx)
        var queue = root.pendingChildren(basePath: path).map { Unit(placeholder: $0.0, path: $0.1, depth: 1) }
        await model.installScanRoot(root, ctx: ctx)

        let limit = max(4, min(12, ProcessInfo.processInfo.activeProcessorCount))
        var head = 0

        await withTaskGroup(of: [Unit].self) { group in
            var running = 0
            func launch() {
                while running < limit, head < queue.count, !ctx.isCancelled {
                    let unit = queue[head]
                    head += 1
                    running += 1
                    group.addTask { scan(unit, ctx: ctx) }
                }
                // Drop consumed entries now and then so the queue does not grow without bound.
                if head > 4096 {
                    queue.removeFirst(head)
                    head = 0
                }
            }
            launch()
            while let next = await group.next() {
                running -= 1
                queue.append(contentsOf: next)
                launch()
            }
        }

        await model.scanFinished(ctx: ctx)
    }

    private static func scan(_ unit: Unit, ctx: ScanContext) -> [Unit] {
        let shallow = unit.depth < expandDepth
        let scanned = Scanner.scan(path: unit.path, shallow: shallow, ctx: ctx)
        let next = shallow
            ? scanned.pendingChildren(basePath: unit.path).map { Unit(placeholder: $0.0, path: $0.1, depth: unit.depth + 1) }
            : []
        // Delivered before its subfolders can finish, which keeps parents ahead of children.
        ctx.deliver(unit.placeholder, scanned)
        return next
    }
}

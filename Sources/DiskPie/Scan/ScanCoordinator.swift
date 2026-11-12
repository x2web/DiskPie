import Foundation

/// Progressive parallel scan: list the root, then its subfolders, then scan grandchildren fully in parallel.
/// Each finished piece is attached on the main actor, so the chart fills in while scanning.
enum ScanCoordinator {
    static func run(path: String, ctx: ScanContext, model: AppModel) async {
        let root = Scanner.scan(path: path, shallow: true, ctx: ctx)
        let level1 = root.pendingChildren(basePath: path)
        await model.installScanRoot(root, ctx: ctx)

        let limit = max(4, min(10, ProcessInfo.processInfo.activeProcessorCount))
        var units: [(FileNode, String)] = []

        await forEachConcurrently(level1, limit: limit, ctx: ctx) { item in
            let sub = Scanner.scan(path: item.1, shallow: true, ctx: ctx)
            return (item.0, sub, sub.pendingChildren(basePath: item.1))
        } onResult: { placeholder, sub, pending in
            await model.fill(placeholder, with: sub, ctx: ctx)
            units.append(contentsOf: pending)
        }

        await forEachConcurrently(units, limit: limit, ctx: ctx) { item in
            (item.0, Scanner.scan(path: item.1, shallow: false, ctx: ctx))
        } onResult: { placeholder, sub in
            await model.fill(placeholder, with: sub, ctx: ctx)
        }

        await model.scanFinished(ctx: ctx)
    }

    private static func forEachConcurrently<T: Sendable, R: Sendable>(
        _ items: [T],
        limit: Int,
        ctx: ScanContext,
        work: @escaping @Sendable (T) -> R,
        onResult: (R) async -> Void
    ) async {
        await withTaskGroup(of: R.self) { group in
            var index = 0
            while index < min(limit, items.count) {
                let item = items[index]
                group.addTask { work(item) }
                index += 1
            }
            while let result = await group.next() {
                await onResult(result)
                if index < items.count, !ctx.isCancelled {
                    let item = items[index]
                    group.addTask { work(item) }
                    index += 1
                }
            }
        }
    }
}

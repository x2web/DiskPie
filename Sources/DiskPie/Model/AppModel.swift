import AppKit
import SwiftUI

enum ViewMode: String, CaseIterable, Identifiable {
    case sunburst, treemap
    var id: Self { self }
    var title: String { self == .sunburst ? "Кольца" : "Плитки" }
    var icon: String { self == .sunburst ? "chart.pie" : "square.grid.3x3.square" }
}

enum ZoomDirection { case into, outOf }

struct AggregateHover: Equatable {
    let parent: FileNode
    let count: Int
    let size: Int64

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.parent === rhs.parent && lhs.count == rhs.count && lhs.size == rhs.size
    }
}

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    // MARK: Tree state
    var root: FileNode?
    var focus: FileNode?
    var rootPath = ""
    var treeVersion = 0
    var isScanning = false
    var isPartial = false
    var progress = ScanProgress()
    var scanStarted: Date?
    var scanDuration: TimeInterval?
    var scanDate: Date?
    var busyWriting = false

    // MARK: UI state
    var hovered: FileNode?
    var hoveredAggregate: AggregateHover?
    var selection: FileNode?
    var contextTarget: FileNode?
    var viewMode: ViewMode = .sunburst
    var showInspector = true
    var inspectorTab: InspectorTab = .contents
    var hasFullDiskAccess = DiskAccess.hasFullDiskAccess()
    var showOnboarding = false
    var quickLookURL: URL?
    var zoomDirection: ZoomDirection = .into
    var collector: [FileNode] = []
    let devCaches = DevCacheStore()
    let duplicates = DuplicateSearch()
    var ringDepth: Int = UserDefaults.standard.object(forKey: "ringDepth") as? Int ?? 5 {
        didSet { UserDefaults.standard.set(ringDepth, forKey: "ringDepth") }
    }

    private var backStack: [FileNode] = []
    private var forwardStack: [FileNode] = []
    @ObservationIgnored private var ctx: ScanContext?
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored var skipPaths: Set<String> = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { focus?.parent != nil }
    var actionTarget: FileNode? { hovered ?? selection }
    var windowTitle: String { root?.displayName ?? "DiskPie" }

    // MARK: Launch & access

    func onLaunch() {
        refreshAccessStatus()
        if !hasFullDiskAccess && !UserDefaults.standard.bool(forKey: "onboardingShown") {
            UserDefaults.standard.set(true, forKey: "onboardingShown")
            showOnboarding = true
        }
    }

    func refreshAccessStatus() {
        hasFullDiskAccess = DiskAccess.hasFullDiskAccess()
    }

    // MARK: Scanning

    func startScan(path: String) {
        cancelScan()
        resetTree()
        rootPath = path
        skipPaths = DiskAccess.skipPaths(forRoot: path)
        isScanning = true
        isPartial = false
        progress = ScanProgress()
        scanStarted = Date()
        scanDuration = nil
        let ctx = ScanContext(skipPaths: skipPaths)
        self.ctx = ctx
        startProgressTimer()
        Task.detached(priority: .userInitiated) { [self] in
            await ScanCoordinator.run(path: path, ctx: ctx, model: self)
        }
    }

    func chooseFolderAndScan() {
        guard let path = chooseFolder() else { return }
        startScan(path: path)
    }

    func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.prompt = "Сканировать"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    func handleDrop(_ urls: [URL]) -> Bool {
        guard let url = urls.first else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return false }
        startScan(path: url.path)
        return true
    }

    func cancelScan() {
        ctx?.cancel()
    }

    func rescanAll() {
        guard !rootPath.isEmpty else { return }
        startScan(path: rootPath)
    }

    func closeScan() {
        cancelScan()
        ctx = nil
        stopProgressTimer()
        isScanning = false
        resetTree()
        rootPath = ""
    }

    private func resetTree() {
        root = nil
        focus = nil
        hovered = nil
        hoveredAggregate = nil
        selection = nil
        contextTarget = nil
        collector = []
        backStack = []
        forwardStack = []
        treeVersion += 1
    }

    func installScanRoot(_ node: FileNode, ctx: ScanContext) {
        guard ctx === self.ctx else { return }
        root = node
        focus = node
        treeVersion += 1
    }

    func fill(_ placeholder: FileNode, with sub: FileNode, ctx: ScanContext) {
        guard ctx === self.ctx else { return }
        replaceContents(of: placeholder, with: sub)
    }

    func scanFinished(ctx: ScanContext) {
        guard ctx === self.ctx else { return }
        stopProgressTimer()
        progress = ctx.snapshot()
        isPartial = ctx.isCancelled
        isScanning = false
        scanDate = Date()
        scanDuration = scanStarted.map { Date().timeIntervalSince($0) }
        self.ctx = nil
        if let root, !isPartial { addHiddenSpaceNode(to: root) }
        treeVersion += 1
        didFinishScan()
    }

    /// Hook for features that react to a completed scan.
    func didFinishScan() {}

    private func addHiddenSpaceNode(to root: FileNode) {
        guard DiskAccess.isVolumeRoot(rootPath), let usage = DiskAccess.volumeUsage(path: rootPath) else { return }
        let hiddenSize = usage.used - root.size
        guard hiddenSize > 0 else { return }
        let node = FileNode(name: "Системное и скрытое", kind: .hidden, size: hiddenSize)
        node.parent = root
        root.children.append(node)
        root.size += hiddenSize
        root.sortChildren()
    }

    private func startProgressTimer() {
        stopProgressTimer()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func tick() {
        if let ctx { progress = ctx.snapshot() }
        if dirty {
            dirty = false
            treeVersion += 1
        }
    }

    // MARK: Tree mutation (main actor only)

    /// Swaps node contents for a freshly scanned subtree and fixes sizes up the chain.
    func replaceContents(of node: FileNode, with sub: FileNode) {
        let old = node.children
        let keep = Set(sub.children.map(ObjectIdentifier.init))
        let removed = old.filter { !keep.contains(ObjectIdentifier($0)) }
        node.adopt(sub.children)
        node.isPending = false
        if sub.kind == .inaccessible { node.kind = .inaccessible }
        node.modified = max(node.modified, sub.modified)
        let sizeDelta = sub.size - node.size
        let countDelta = sub.fileCount - node.fileCount
        node.sortChildren()
        node.applyDelta(size: sizeDelta, count: countDelta)
        if removed.isEmpty {
            markDirty()
        } else {
            sanitize(removedRoots: removed)
            treeVersion += 1
        }
    }

    func detach(_ nodes: [FileNode]) {
        let roots = nodes.filter { node in
            node.parent != nil && !nodes.contains { $0 !== node && node.isDescendant(of: $0) }
        }
        guard !roots.isEmpty else { return }
        for node in roots {
            guard let parent = node.parent else { continue }
            parent.children.removeAll { $0 === node }
            parent.applyDelta(size: -node.size, count: -node.fileCount)
        }
        sanitize(removedRoots: roots)
        treeVersion += 1
    }

    private func markDirty() {
        if isScanning { dirty = true } else { treeVersion += 1 }
    }

    /// Drops references into removed subtrees while those subtrees are still alive.
    private func sanitize(removedRoots: [FileNode]) {
        guard !removedRoots.isEmpty else { return }
        func isRemoved(_ node: FileNode) -> Bool {
            removedRoots.contains { node.isDescendant(of: $0) }
        }
        if let focus, isRemoved(focus) {
            let removedRoot = removedRoots.first { focus.isDescendant(of: $0) }
            self.focus = removedRoot?.parent ?? root
        }
        if let hovered, isRemoved(hovered) { self.hovered = nil }
        if let aggregate = hoveredAggregate, isRemoved(aggregate.parent) { hoveredAggregate = nil }
        if let selection, isRemoved(selection) { self.selection = nil }
        if let contextTarget, isRemoved(contextTarget) { self.contextTarget = nil }
        collector.removeAll(where: isRemoved)
        backStack.removeAll(where: isRemoved)
        forwardStack.removeAll(where: isRemoved)
    }

    func node(atPath rawPath: String) -> FileNode? {
        guard let (node, exact) = resolve(rawPath), exact else { return nil }
        return node
    }

    /// Deepest node on the way to `path` and whether it matches exactly.
    func resolve(_ rawPath: String) -> (FileNode, Bool)? {
        guard let root else { return nil }
        var path = rawPath
        if !rootPath.hasPrefix(DiskAccess.dataVolume) { path = DiskAccess.normalize(path) }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        if path == rootPath { return (root, true) }
        let base = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(base) else { return nil }
        var node = root
        for component in path.dropFirst(base.count).split(separator: "/") {
            guard let child = node.child(named: component) else { return (node, false) }
            node = child
        }
        return (node, true)
    }

    // MARK: Navigation

    func enter(_ node: FileNode) {
        guard node.isContainer, node !== focus, node.size > 0 || !node.children.isEmpty else { return }
        if let focus { backStack.append(focus) }
        forwardStack.removeAll()
        setFocus(node, direction: .into)
    }

    func goUp() {
        guard let parent = focus?.parent else { return }
        if let focus { backStack.append(focus) }
        forwardStack.removeAll()
        let previous = focus
        setFocus(parent, direction: .outOf)
        selection = previous
    }

    func goToRoot() {
        guard let root, root !== focus else { return }
        if let focus { backStack.append(focus) }
        forwardStack.removeAll()
        setFocus(root, direction: .outOf)
    }

    func goBack() {
        guard let target = backStack.popLast() else { return }
        if let focus { forwardStack.append(focus) }
        setFocus(target, direction: target.isDescendant(of: focus ?? target) ? .into : .outOf)
    }

    func goForward() {
        guard let target = forwardStack.popLast() else { return }
        if let focus { backStack.append(focus) }
        setFocus(target, direction: target.isDescendant(of: focus ?? target) ? .into : .outOf)
    }

    func navigate(to node: FileNode) {
        if node.isContainer {
            enter(node)
        } else if let parent = node.parent {
            if parent !== focus { enter(parent) }
            selection = node
        }
    }

    func reveal(_ node: FileNode) {
        if let parent = node.parent, parent !== focus { enter(parent) }
        selection = node
        inspectorTab = .contents
    }

    private func setFocus(_ node: FileNode, direction: ZoomDirection) {
        zoomDirection = direction
        hovered = nil
        hoveredAggregate = nil
        withAnimation(.easeInOut(duration: 0.28)) {
            focus = node
        }
    }

    // MARK: Hover & selection

    func hover(_ node: FileNode?) {
        if hovered !== node { hovered = node }
        if hoveredAggregate != nil { hoveredAggregate = nil }
        if let node { contextTarget = node }
    }

    func hover(aggregate: AggregateHover) {
        if hovered != nil { hovered = nil }
        if hoveredAggregate != aggregate { hoveredAggregate = aggregate }
        contextTarget = aggregate.parent
    }

    func select(_ node: FileNode?) {
        selection = node
        if let node { contextTarget = node }
    }

    // MARK: Item actions

    func open(_ node: FileNode) {
        if node.isContainer && node.kind != .package {
            enter(node)
        } else {
            NSWorkspace.shared.open(node.url)
        }
    }

    func revealInFinder(_ node: FileNode) {
        guard node.kind != .hidden else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func copyPath(_ node: FileNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    func quickLook(_ node: FileNode?) {
        guard let node, node.kind != .hidden else { return }
        quickLookURL = node.url
    }

    func isInCollector(_ node: FileNode) -> Bool {
        collector.contains { node.isDescendant(of: $0) }
    }

    func toggleCollector(_ node: FileNode) {
        guard node.isActionable else { return }
        if let index = collector.firstIndex(where: { $0 === node }) {
            collector.remove(at: index)
        } else if !isInCollector(node) {
            collector.removeAll { $0.isDescendant(of: node) }
            collector.append(node)
        }
    }

    var collectorTotal: Int64 { collector.reduce(0) { $0 + $1.size } }

    // MARK: Deletion

    func trash(_ nodes: [FileNode], permanently: Bool = false) {
        trash(paths: nodes.filter(\.isActionable).map(\.path), permanently: permanently)
    }

    /// Moves paths to the Trash (or deletes them) after confirmation and drops them from the tree.
    func trash(paths: [String], permanently: Bool = false, title: String? = nil) {
        guard !paths.isEmpty else { return }
        if isScanning || busyWriting {
            showMessage("Подождите", "Удаление недоступно, пока идёт сканирование или сохранение снимка.")
            return
        }
        if let protected = paths.first(where: DiskAccess.isProtected) {
            showMessage("Системный путь", "«\(protected)» удалять нельзя.")
            return
        }
        let nodes = paths.compactMap(node(atPath:))
        let total = nodes.reduce(Int64(0)) { $0 + $1.size }
        let names = paths.prefix(6).map { "• " + ($0 as NSString).lastPathComponent }.joined(separator: "\n")
        let more = paths.count > 6 ? "\n…и ещё \(paths.count - 6)" : ""
        let sizeLine = total > 0 ? "\n\nВсего: \(Fmt.size(total))" : ""

        let alert = NSAlert()
        alert.alertStyle = permanently ? .critical : .warning
        alert.messageText = title ?? (permanently ? "Удалить безвозвратно?" : "Переместить в Корзину?")
        alert.informativeText = names + more + sizeLine + (permanently ? "\n\nЭто действие нельзя отменить." : "")
        alert.addButton(withTitle: permanently ? "Удалить" : "В Корзину")
        alert.addButton(withTitle: "Отмена")
        if permanently { alert.buttons.first?.hasDestructiveAction = true }
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var removedPaths: [String] = []
        var errors: [String] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            do {
                if permanently {
                    try FileManager.default.removeItem(at: url)
                } else {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
                removedPaths.append(path)
            } catch {
                errors.append("\((path as NSString).lastPathComponent): \(error.localizedDescription)")
            }
        }
        detach(removedPaths.compactMap(node(atPath:)))
        didRemove(paths: removedPaths)
        if !errors.isEmpty {
            showMessage("Не всё удалось удалить", errors.prefix(10).joined(separator: "\n"))
        }
    }

    private func didRemove(paths: [String]) {
        duplicates.forget(paths: paths)
    }

    /// Empties a cache folder by moving its contents to the Trash, then refreshes the tree and sizes.
    func cleanContents(of item: DevCacheItem) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: item.path), !names.isEmpty else {
            showMessage("Пусто", "В «\(item.title)» нечего удалять.")
            return
        }
        let base = item.path.hasSuffix("/") ? item.path : item.path + "/"
        trash(paths: names.map { base + $0 }, title: "Очистить «\(item.title)»?")
        devCaches.measure()
    }

    func trashCollector() {
        trash(collector)
    }

    func showMessage(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: Subtree rescan

    func rescan(_ node: FileNode) {
        guard !isScanning else { return }
        if node.isRoot {
            rescanAll()
            return
        }
        guard node.isContainer else { return }
        let path = node.path
        let skip = skipPaths
        Task.detached(priority: .userInitiated) { [self] in
            let sub = Scanner.scan(path: path, shallow: false, ctx: ScanContext(skipPaths: skip))
            await applyRescan(sub, path: path)
        }
    }

    private func applyRescan(_ sub: FileNode, path: String) {
        guard !isScanning, !busyWriting, let node = node(atPath: path) else { return }
        replaceContents(of: node, with: sub)
        treeVersion += 1
    }
}

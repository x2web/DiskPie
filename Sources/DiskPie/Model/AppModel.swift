import AppKit
import CoreServices
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
    /// Snapshot writers reading the tree in the background; the tree must not change meanwhile.
    var writers = 0
    var busyWriting: Bool { writers > 0 }
    /// Scanned sum above the volume's used space: APFS clones are counted once per copy.
    var cloneOvercount: Int64 = 0

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
    var cachedMeta: ScanMeta?
    var recentScans: [ScanMeta] = ScanStore.all()
    var liveUpdates = UserDefaults.standard.bool(forKey: "liveUpdates") {
        didSet {
            UserDefaults.standard.set(liveUpdates, forKey: "liveUpdates")
            configureWatcher()
        }
    }
    var liveChanges = 0
    var ringDepth: Int = UserDefaults.standard.object(forKey: "ringDepth") as? Int ?? 5 {
        didSet { UserDefaults.standard.set(ringDepth, forKey: "ringDepth") }
    }

    private var backStack: [FileNode] = []
    private var forwardStack: [FileNode] = []
    @ObservationIgnored private var ctx: ScanContext?
    @ObservationIgnored private var progressTimer: Timer?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored var skipPaths: Set<String> = []
    /// Bumped whenever the shown tree is replaced; late async results for an older tree are dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var links = HardLinkRegistry()
    @ObservationIgnored private var adminProcess: ProcessBox?
    @ObservationIgnored private var watcher: LiveWatcher?
    @ObservationIgnored private var pendingEvents: [String: Bool] = [:]
    @ObservationIgnored private var eventFlush: DispatchWorkItem?

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { focus?.parent != nil }
    var actionTarget: FileNode? { hovered ?? selection }
    /// Keyboard deletion acts on the explicit selection only, never on whatever is under the cursor.
    var deleteTarget: FileNode? { selection }

    func isAttached(_ node: FileNode) -> Bool {
        root != nil && node.root === root
    }
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
        stopWatcher()
        resetTree()
        cachedMeta = nil
        rootPath = path
        skipPaths = DiskAccess.skipPaths(forRoot: path)
        isScanning = true
        isPartial = false
        progress = ScanProgress()
        scanStarted = Date()
        scanDuration = nil
        generation += 1
        links = HardLinkRegistry()
        let ctx = ScanContext(skipPaths: skipPaths, links: links)
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
        adminProcess?.terminate()
    }

    func rescanAll() {
        guard !rootPath.isEmpty else { return }
        startScan(path: rootPath)
    }

    func closeScan() {
        cancelScan()
        stopWatcher()
        cachedMeta = nil
        recentScans = ScanStore.all()
        generation += 1
        ctx = nil
        adminProcess = nil
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
        cloneOvercount = 0
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

    private func didFinishScan() {
        saveSnapshot()
        configureWatcher()
    }

    // MARK: Snapshots

    private func saveSnapshot() {
        guard let root, let date = scanDate else { return }
        let path = rootPath, partial = isPartial
        writers += 1
        Task.detached(priority: .utility) { [self] in
            let meta = try? ScanStore.save(root, rootPath: path, date: date, partial: partial)
            await MainActor.run {
                writers -= 1
                if meta != nil { recentScans = ScanStore.all() }
            }
        }
    }

    func openSnapshot(_ meta: ScanMeta) {
        cancelScan()
        stopWatcher()
        ctx = nil
        adminProcess = nil
        stopProgressTimer()
        isScanning = false
        generation += 1
        let expected = generation
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let root = try ScanStore.load(meta)
                await MainActor.run {
                    guard expected == generation else { return }
                    installCompletedTree(root, path: meta.rootPath, date: meta.date, partial: meta.partial, addHidden: false)
                    cachedMeta = meta
                }
            } catch {
                await MainActor.run {
                    guard expected == generation else { return }
                    showMessage("Не удалось открыть снимок", error.localizedDescription)
                }
            }
        }
    }

    func deleteSnapshot(_ meta: ScanMeta) {
        ScanStore.delete(meta)
        recentScans = ScanStore.all()
    }

    func deleteAllSnapshots() {
        ScanStore.deleteAll()
        recentScans = []
    }

    /// Older snapshots of the current root, newest first.
    var previousSnapshots: [ScanMeta] {
        let current = scanDate ?? .distantFuture
        return recentScans.filter { $0.rootPath == rootPath && $0.date < current.addingTimeInterval(-1) }
    }

    private func installCompletedTree(_ node: FileNode, path: String, date: Date, partial: Bool, addHidden: Bool) {
        resetTree()
        rootPath = path
        skipPaths = DiskAccess.skipPaths(forRoot: path)
        isScanning = false
        isPartial = partial
        scanDate = date
        scanDuration = nil
        progress = ScanProgress(files: node.fileCount, bytes: node.size)
        links = HardLinkRegistry()
        if addHidden { addHiddenSpaceNode(to: node) }
        root = node
        focus = node
        treeVersion += 1
    }

    // MARK: Administrator scan

    func chooseFolderAndScanAsAdmin() {
        guard let path = chooseFolder() else { return }
        scanAsAdmin(path: path)
    }

    func scanAsAdmin(path: String) {
        cancelScan()
        stopWatcher()
        resetTree()
        cachedMeta = nil
        rootPath = path
        isScanning = true
        progress = ScanProgress(current: "Сканирование с правами администратора…")
        scanStarted = Date()
        generation += 1
        let ctx = ScanContext(skipPaths: [])
        self.ctx = ctx
        let box = ProcessBox()
        adminProcess = box
        Task.detached(priority: .userInitiated) { [self] in
            do {
                let (root, inaccessible) = try await PrivilegedScan.run(path: path, box: box)
                await MainActor.run {
                    guard ctx === self.ctx else { return }
                    if ctx.isCancelled {
                        closeScan()
                        return
                    }
                    self.ctx = nil
                    adminProcess = nil
                    let started = scanStarted
                    installCompletedTree(root, path: path, date: Date(), partial: false, addHidden: true)
                    progress.inaccessible = inaccessible
                    scanDuration = started.map { Date().timeIntervalSince($0) }
                    saveSnapshot()
                    configureWatcher()
                }
            } catch {
                await MainActor.run {
                    guard ctx === self.ctx else { return }
                    closeScan()
                    if ctx.isCancelled { return }
                    if case PrivilegedScan.Failure.cancelled = error { return }
                    showMessage("Скан от администратора не удался", error.localizedDescription)
                }
            }
        }
    }

    // MARK: Live updates

    private func configureWatcher() {
        stopWatcher()
        guard liveUpdates, !isScanning, root != nil, !rootPath.isEmpty else { return }
        let watcher = LiveWatcher(path: rootPath) { [weak self] paths, flags in
            MainActor.assumeIsolated { self?.handleFSEvents(paths, flags) }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func stopWatcher() {
        watcher?.stop()
        watcher = nil
        eventFlush?.cancel()
        pendingEvents = [:]
    }

    private func handleFSEvents(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        guard !isScanning, root != nil else { return }
        for (index, raw) in paths.enumerated() {
            var path = raw
            while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
            if !rootPath.hasPrefix(DiskAccess.dataVolume) { path = DiskAccess.normalize(path) }
            if skipPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
            let deep = index < flags.count && flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            pendingEvents[path] = (pendingEvents[path] ?? false) || deep
        }
        scheduleEventFlush()
    }

    private func scheduleEventFlush() {
        eventFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flushEvents() }
        }
        eventFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func flushEvents() {
        guard !pendingEvents.isEmpty else { return }
        if busyWriting || isScanning {
            scheduleEventFlush()
            return
        }
        var targets: [String: Bool] = [:]
        for (path, deep) in pendingEvents {
            guard let (node, exact) = resolve(path) else { continue }
            let directory = node.isContainer ? node : (node.parent ?? node)
            let key = directory.path
            targets[key] = (targets[key] ?? false) || (deep && exact)
        }
        pendingEvents = [:]
        let deepRoots = targets.filter(\.value).map(\.key)
        for (path, deep) in targets {
            let coveredByDeep = deepRoots.contains { $0 != path && path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
            if !coveredByDeep { refreshDirectory(path: path, deep: deep) }
        }
    }

    private func refreshDirectory(path: String, deep: Bool) {
        let skip = skipPaths, links = links, expected = generation
        Task.detached(priority: .utility) { [self] in
            let listing = Scanner.scan(path: path, shallow: !deep, ctx: ScanContext(skipPaths: skip, links: links))
            await merge(listing, path: path, deep: deep, generation: expected)
        }
    }

    /// Runs `apply` when the tree may change, or retries shortly while a snapshot is being written.
    private func whenTreeWritable(generation expected: Int, _ apply: @escaping () -> Void) {
        guard expected == generation, !isScanning else { return }
        if busyWriting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.whenTreeWritable(generation: expected, apply) }
            }
            return
        }
        apply()
    }

    private func merge(_ listing: FileNode, path: String, deep: Bool, generation expected: Int) {
        whenTreeWritable(generation: expected) { [self] in applyListing(listing, path: path, deep: deep) }
    }

    /// Shallow refresh keeps known subfolders and scans only new ones.
    private func applyListing(_ listing: FileNode, path: String, deep: Bool) {
        guard let node = node(atPath: path), node.isContainer else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            detach([node])
            liveChanges += 1
            return
        }
        // A failed read must not wipe the known subtree.
        guard listing.kind != .inaccessible else { return }
        if deep {
            replaceContents(of: node, with: listing)
            restoreHiddenNode(after: node)
            liveChanges += 1
            return
        }
        var known: [String: FileNode] = [:]
        for child in node.children where child.isContainer && !child.isPending { known[child.name] = child }
        var merged: [FileNode] = []
        var newDirectories: [String] = []
        let base = path.hasSuffix("/") ? path : path + "/"
        for child in listing.children {
            if child.isContainer, let existing = known[child.name] {
                merged.append(existing)
            } else {
                merged.append(child)
                if child.isPending { newDirectories.append(base + child.name) }
            }
        }
        let update = FileNode(name: node.name, kind: node.kind)
        update.children = merged
        update.size = merged.reduce(0) { $0 + $1.size }
        update.fileCount = merged.reduce(0) { $0 + $1.fileCount }
        update.modified = listing.modified
        replaceContents(of: node, with: update)
        restoreHiddenNode(after: node)
        liveChanges += 1
        for directory in newDirectories { refreshDirectory(path: directory, deep: true) }
    }

    /// Refreshing the root drops the synthetic hidden-space node; recompute it.
    private func restoreHiddenNode(after node: FileNode) {
        guard node === root, !node.children.contains(where: { $0.kind == .hidden }) else { return }
        addHiddenSpaceNode(to: node)
        treeVersion += 1
    }

    private func addHiddenSpaceNode(to root: FileNode) {
        cloneOvercount = 0
        guard DiskAccess.isVolumeRoot(rootPath), let usage = DiskAccess.volumeUsage(path: rootPath) else { return }
        let hiddenSize = usage.used - root.size
        guard hiddenSize > 0 else {
            cloneOvercount = -hiddenSize
            return
        }
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
        // Views may still hold removed nodes until they re-render; cut them loose so nothing walks
        // into a freed parent.
        for removed in removedRoots {
            Analyses.walk(removed) { $0.parent = nil }
        }
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
        guard isAttached(node), node.isContainer, node !== focus, node.size > 0 || !node.children.isEmpty else { return }
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

    func unhover(_ node: FileNode) {
        if hovered === node { hovered = nil }
    }

    func select(_ node: FileNode?) {
        selection = node
        if let node { contextTarget = node }
    }

    // MARK: Item actions

    func open(_ node: FileNode) {
        guard isAttached(node) else { return }
        if node.isContainer && node.kind != .package {
            enter(node)
        } else {
            NSWorkspace.shared.open(node.url)
        }
    }

    func revealInFinder(_ node: FileNode) {
        guard isAttached(node), node.kind != .hidden else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    func copyPath(_ node: FileNode) {
        guard isAttached(node) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(node.path, forType: .string)
    }

    func quickLook(_ node: FileNode?) {
        guard let node, isAttached(node), node.kind != .hidden else { return }
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
        if node === root {
            rescanAll()
            return
        }
        guard node.isContainer, node.parent != nil else { return }
        let path = node.path
        let skip = skipPaths, links = links, expected = generation
        Task.detached(priority: .userInitiated) { [self] in
            let sub = Scanner.scan(path: path, shallow: false, ctx: ScanContext(skipPaths: skip, links: links))
            await MainActor.run {
                whenTreeWritable(generation: expected) { [self] in applyListing(sub, path: path, deep: true) }
            }
        }
    }
}

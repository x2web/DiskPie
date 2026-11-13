import AppKit
import SwiftUI

/// `DiskPie --render <path> <out.png> [sunburst|treemap] [subpath]` scans a folder and renders the chart
/// offscreen. Used to check the layout without screen-recording permission.
enum DebugRender {
    @MainActor
    static func run(arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--render"), arguments.count > index + 2 else {
            FileHandle.standardError.write(Data("usage: --render <path> <out.png> [sunburst|treemap] [focus-subpath]\n".utf8))
            return 2
        }
        let path = arguments[index + 1]
        let out = arguments[index + 2]
        let mode = arguments.count > index + 3 ? arguments[index + 3] : "sunburst"
        let focusPath = arguments.count > index + 4 ? arguments[index + 4] : nil

        let start = Date()
        let model = AppModel.shared
        // Same progressive parallel pipeline as the app.
        model.startScan(path: path)
        while model.isScanning || model.busyWriting {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let root = model.root else { return 1 }
        let progress = model.progress
        print("scanned \(path): \(Fmt.size(root.size)) (\(root.size) bytes), \(progress.files) files, \(progress.dirs) dirs, \(progress.inaccessible) inaccessible, \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
        print("top level: " + root.children.prefix(8).map { "\($0.name) \(Fmt.size($0.size))" }.joined(separator: ", "))
        if let focusPath, let node = model.node(atPath: focusPath) { model.focus = node }
        guard let focus = model.focus else { return 1 }

        let chart: AnyView = mode == "treemap"
            ? AnyView(TreemapView(focus: focus, version: 0))
            : AnyView(SunburstView(focus: focus, version: 0, depth: model.ringDepth))
        let content = chart
            .environment(model)
            .frame(width: 900, height: 900)
            .background(Color(nsColor: .windowBackgroundColor))

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return 1 }
        do {
            try png.write(to: URL(fileURLWithPath: out))
        } catch {
            print(error)
            return 1
        }
        return 0
    }
}

/// `DiskPie --analyze <path>` prints what the inspector panels would show.
enum DebugAnalyze {
    static func run(arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--analyze"), arguments.count > index + 1 else { return 2 }
        let path = arguments[index + 1]
        let root = Scanner.scan(path: path, shallow: false, ctx: ScanContext(skipPaths: DiskAccess.skipPaths(forRoot: path)))
        print("total \(Fmt.size(root.size)), \(Fmt.files(root.fileCount))")
        print("-- largest files")
        for node in Analyses.largestFiles(in: root, limit: 5) { print(Fmt.size(node.size), node.path) }
        print("-- categories")
        for stat in Analyses.categories(in: root) { print(stat.category.title, Fmt.size(stat.size), stat.count) }
        print("-- build artifacts")
        for node in Analyses.buildArtifacts(in: root, limit: 5) { print(Fmt.size(node.size), node.path) }
        let old = Analyses.oldFiles(in: root, olderThan: Date().addingTimeInterval(-365 * 86400))
        print("-- older than a year: \(old.count) files, \(Fmt.size(old.total))")
        var files: [(path: String, size: Int64)] = []
        Analyses.walk(root) { if $0.kind == .file, $0.size >= 100_000 { files.append(($0.path, $0.size)) } }
        let groups = DuplicateFinder.find(files, cancel: CancelFlag()) { _, _ in }
        print("-- duplicates: \(groups.count) groups, wasted \(Fmt.size(groups.reduce(0) { $0 + $1.wasted }))")
        for group in groups.prefix(3) { print(Fmt.size(group.size), group.paths) }
        do {
            let start = Date()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("diskpie-test.dpscan")
            defer { try? FileManager.default.removeItem(at: file) }
            try ScanArchive.write(root, rootPath: path, date: Date(), partial: false, to: file)
            let data = try Data(contentsOf: file)
            let (header, copy) = try ScanArchive.decode(data)
            print("-- archive: \(Fmt.size(Int64(data.count))), roundtrip \(String(format: "%.2f", Date().timeIntervalSince(start))) s, root \(header.rootPath), size match \(copy.size == root.size), count match \(copy.fileCount == root.fileCount)")
            if let victim = Analyses.largestFiles(in: copy, limit: 1).first { victim.parent?.applyDelta(size: -victim.size, count: -1); victim.parent?.children.removeAll { $0 === victim } }
            let changes = Analyses.changes(current: root, previous: copy, rootPath: path, threshold: 1_000_000)
            print("-- changes vs copy without largest file: \(changes.map { "\($0.path) \(Fmt.signedSize($0.delta)) new=\($0.isNew)" })")
        } catch {
            print("archive error \(error)")
            return 1
        }
        return 0
    }
}

/// `DiskPie --denied <path>` lists folders the scan could not read, grouped by error.
enum DebugDenied {
    static func run(arguments: [String]) -> Int32 {
        guard let index = arguments.firstIndex(of: "--denied"), arguments.count > index + 1 else { return 2 }
        let path = arguments[index + 1]
        let ctx = ScanContext(skipPaths: DiskAccess.skipPaths(forRoot: path))
        _ = Scanner.scan(path: path, shallow: false, ctx: ctx)
        print("full disk access: \(DiskAccess.hasFullDiskAccess())")
        for group in DeniedReason.group(ctx.deniedPaths) {
            print("== \(group.reason.title) (\(group.paths.count))")
            for item in group.paths.prefix(40) { print("  \(item.path)") }
        }
        return 0
    }
}

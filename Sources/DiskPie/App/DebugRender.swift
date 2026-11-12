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
        let ctx = ScanContext(skipPaths: DiskAccess.skipPaths(forRoot: path))
        let root = Scanner.scan(path: path, shallow: false, ctx: ctx)
        let progress = ctx.snapshot()
        print("scanned \(path): \(Fmt.size(root.size)) (\(root.size) bytes), \(progress.files) files, \(progress.dirs) dirs, \(progress.inaccessible) inaccessible, \(String(format: "%.2f", Date().timeIntervalSince(start))) s")

        let model = AppModel.shared
        model.root = root
        model.rootPath = path
        model.focus = root
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

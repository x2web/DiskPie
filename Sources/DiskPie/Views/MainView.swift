import SwiftUI

struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HeaderBar()
            Divider()
            ChartArea()
            Divider()
            StatusBar()
        }
        .inspector(isPresented: $model.showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 300, ideal: 380, max: 640)
        }
        .toolbar { MainToolbar() }
        .navigationTitle(model.windowTitle)
    }
}

struct MainToolbar: ToolbarContent {
    @Environment(AppModel.self) private var model

    var body: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .help(String(localized: "Back")).disabled(!model.canGoBack)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .help(String(localized: "Forward")).disabled(!model.canGoForward)
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .help(String(localized: "Enclosing folder (Esc)")).disabled(!model.canGoUp)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker(String(localized: "View"), selection: $model.viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Image(systemName: mode.icon).help(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Menu {
                Button(String(localized: "Home Folder")) { model.startScan(path: NSHomeDirectory()) }
                Button(String(localized: "Startup Disk")) { model.startScan(path: "/") }
                Button(String(localized: "Choose Folder…")) { model.chooseFolderAndScan() }
                ScanMenuExtras()
                Divider()
                Button(String(localized: "Close Scan")) { model.closeScan() }
            } label: {
                Image(systemName: "externaldrive")
            }
            .help(String(localized: "What to scan"))

            if model.isScanning {
                Button { model.cancelScan() } label: { Image(systemName: "stop.circle") }
                    .help(String(localized: "Stop"))
            } else {
                Button { model.rescanAll() } label: { Image(systemName: "arrow.clockwise") }
                    .help(String(localized: "Rescan (⌘R)"))
            }
            ToolbarExtras()
        }
    }
}



struct HeaderBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Breadcrumbs()
            HoverLine()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct Breadcrumbs: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                if let focus = model.focus {
                    let chain = focus.ancestors
                    ForEach(Array(chain.enumerated()), id: \.offset) { index, node in
                        if index > 0 {
                            Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                        }
                        Button {
                            if node !== model.focus { model.navigate(to: node) }
                        } label: {
                            HStack(spacing: 4) {
                                if index == 0 { Image(systemName: "internaldrive") }
                                Text(index == 0 ? node.displayName : node.name)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(node === model.focus ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .help(node.path)
                    }
                }
            }
            .font(.callout)
        }
    }
}

struct HoverLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let focusSize = model.focus?.size ?? 0
        HStack(spacing: 8) {
            if let node = model.hovered ?? model.selection {
                NodeIcon(node: node)
                Text(node.kind == .hidden ? String(localized: "APFS snapshots, purgeable space, system volumes and anything that could not be read") : node.path)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(Fmt.size(node.size)).bold().monospacedDigit()
                Text(Fmt.percent(node.size, of: focusSize)).foregroundStyle(.secondary).monospacedDigit()
                if node.isContainer {
                    Text(Fmt.files(node.fileCount)).foregroundStyle(.secondary)
                }
            } else if let aggregate = model.hoveredAggregate {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary).frame(width: 18)
                Text(String(localized: "Small items in \(aggregate.parent.path): \(Fmt.count(aggregate.count))"))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Fmt.size(aggregate.size)).bold().monospacedDigit()
                Text(Fmt.percent(aggregate.size, of: focusSize)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "cursorarrow.rays").foregroundStyle(.tertiary).frame(width: 18)
                Text(model.viewMode == .sunburst
                     ? String(localized: "Hover a segment to see its path here. Click to go in, click the center to go up, right-click for actions.")
                     : String(localized: "Hover a tile to see its path here. Click to go in, press Esc to go up, right-click for actions."))
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
        }
        .font(.callout)
        .frame(height: 20)
    }
}

struct ChartArea: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let version = model.treeVersion
        ZStack {
            if let focus = model.focus {
                Group {
                    switch model.viewMode {
                    case .sunburst:
                        SunburstView(focus: focus, version: version, depth: model.ringDepth)
                    case .treemap:
                        TreemapView(focus: focus, version: version)
                    }
                }
                .id(ObjectIdentifier(focus))
                .transition(model.zoomDirection == .into ? .zoomIn : .zoomOut)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

extension AnyTransition {
    static var zoomIn: AnyTransition {
        .asymmetric(insertion: .scale(scale: 0.55).combined(with: .opacity),
                    removal: .scale(scale: 1.5).combined(with: .opacity))
    }

    static var zoomOut: AnyTransition {
        .asymmetric(insertion: .scale(scale: 1.5).combined(with: .opacity),
                    removal: .scale(scale: 0.55).combined(with: .opacity))
    }
}

struct StatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if model.isScanning {
                ProgressView().controlSize(.small)
                Text("\(Fmt.files(model.progress.files)) · \(Fmt.size(model.progress.bytes))")
                    .monospacedDigit()
                Text(model.progress.current)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(String(localized: "Stop")) { model.cancelScan() }.controlSize(.small)
            } else if let root = model.root {
                Text(String(localized: "Total \(Fmt.size(root.size)) · \(Fmt.files(root.fileCount))")).monospacedDigit()
                if let duration = model.scanDuration {
                    Text(String(localized: "in \(Fmt.duration(duration))")).foregroundStyle(.secondary)
                }
                if model.isPartial {
                    Label(String(localized: "scan stopped"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                StatusExtras()
                Spacer()
                if model.cloneOvercount > 0 {
                    Label(String(localized: "+\(Fmt.size(model.cloneOvercount)) over used space"), systemImage: "square.on.square")
                        .foregroundStyle(.secondary)
                        .help(String(localized: "The total exceeds the volume's used space: APFS clones (copies that share data) are counted for every copy."))
                }
                if model.progress.inaccessible > 0 {
                    DeniedButton()
                }
                if let space = model.volumeSpace {
                    FreeSpaceLabel(total: space.total, available: space.available)
                }
                if !model.hasFullDiskAccess {
                    Button {
                        model.showOnboarding = true
                    } label: {
                        Label(String(localized: "No Full Disk Access"), systemImage: "exclamationmark.shield")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.orange)
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(height: 30)
    }
}


struct FreeSpaceLabel: View {
    let total: Int64
    let available: Int64

    var body: some View {
        let used = Double(total - available) / Double(max(1, total))
        HStack(spacing: 6) {
            SizeBar(fraction: used, color: used > 0.9 ? .red : used > 0.75 ? .orange : .green)
                .frame(width: 60)
            Text(String(localized: "\(Fmt.size(available)) free of \(Fmt.size(total))")).monospacedDigit()
        }
        .help(String(localized: "Free space on the volume as Finder counts it, including purgeable space that macOS frees on demand."))
    }
}

struct DeniedButton: View {
    @Environment(AppModel.self) private var model
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Label(String(localized: "no access: \(Fmt.count(model.progress.inaccessible))"), systemImage: "lock")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(String(localized: "Folders that could not be read. Click to see which ones and why."))
        .popover(isPresented: $shown, arrowEdge: .top) { DeniedListView() }
    }
}

struct DeniedListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = DeniedReason.group(model.deniedPaths)
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Could not read")).font(.headline).padding(12)
            if groups.isEmpty {
                Text(String(localized: "The list is not available for this scan (saved scan or administrator scan)."))
                    .foregroundStyle(.secondary).padding([.horizontal, .bottom], 12)
            } else {
                List {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.paths, id: \.self) { item in
                                Text(item.path)
                                    .lineLimit(1).truncationMode(.middle)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                    .contextMenu {
                                        Button(String(localized: "Show in Finder")) {
                                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                                        }
                                        Button(String(localized: "Copy Path")) {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(item.path, forType: .string)
                                        }
                                    }
                            }
                        } header: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(group.reason.title) — \(group.paths.count)")
                                Text(group.reason.hint).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if groups.contains(where: { $0.reason == .permissions }), !model.rootPath.isEmpty {
                    Divider()
                    Button(String(localized: "Rescan as Administrator")) { model.scanAsAdmin(path: model.rootPath) }
                        .padding(12)
                }
            }
        }
        .frame(width: 560, height: 440)
    }
}

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
                .help("Назад").disabled(!model.canGoBack)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .help("Вперёд").disabled(!model.canGoForward)
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .help("Наверх (Esc)").disabled(!model.canGoUp)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Вид", selection: $model.viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Image(systemName: mode.icon).help(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Menu {
                Button("Домашняя папка") { model.startScan(path: NSHomeDirectory()) }
                Button("Загрузочный диск") { model.startScan(path: "/") }
                Button("Выбрать папку…") { model.chooseFolderAndScan() }
                ScanMenuExtras()
                Divider()
                Button("Закрыть скан") { model.closeScan() }
            } label: {
                Image(systemName: "externaldrive")
            }
            .help("Что сканировать")

            if model.isScanning {
                Button { model.cancelScan() } label: { Image(systemName: "stop.circle") }
                    .help("Остановить")
            } else {
                Button { model.rescanAll() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Пересканировать (⌘R)")
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
                Text(node.kind == .hidden ? "Снимки APFS, purgeable-место, системные тома и то, что не удалось прочитать" : node.path)
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
                Text("\(Fmt.count(aggregate.count)) мелких объектов в \(aggregate.parent.path)")
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Fmt.size(aggregate.size)).bold().monospacedDigit()
                Text(Fmt.percent(aggregate.size, of: focusSize)).foregroundStyle(.secondary)
            } else {
                Image(systemName: "cursorarrow.rays").foregroundStyle(.tertiary).frame(width: 18)
                Text("Наведите на сегмент — здесь появится путь. Клик — внутрь, клик по центру — наверх, правая кнопка — действия.")
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
                Button("Остановить") { model.cancelScan() }.controlSize(.small)
            } else if let root = model.root {
                Text("Всего \(Fmt.size(root.size)) · \(Fmt.files(root.fileCount))").monospacedDigit()
                if let duration = model.scanDuration {
                    Text("за \(Fmt.duration(duration))").foregroundStyle(.secondary)
                }
                if model.isPartial {
                    Label("скан прерван", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                StatusExtras()
                Spacer()
                if model.progress.inaccessible > 0 {
                    Label("нет доступа: \(Fmt.count(model.progress.inaccessible))", systemImage: "lock")
                        .foregroundStyle(.secondary)
                        .help("Папки, которые не удалось прочитать")
                }
                if !model.hasFullDiskAccess {
                    Button {
                        model.showOnboarding = true
                    } label: {
                        Label("Нет полного доступа", systemImage: "exclamationmark.shield")
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


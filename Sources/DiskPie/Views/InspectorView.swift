import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case contents, largest, types, old, changes, dev, duplicates, collector

    var id: Self { self }

    var title: String {
        switch self {
        case .contents: String(localized: "Contents")
        case .largest: String(localized: "Largest")
        case .types: String(localized: "File Types")
        case .old: String(localized: "Not Touched Lately")
        case .changes: String(localized: "What Changed")
        case .dev: String(localized: "Developer Caches")
        case .duplicates: String(localized: "Duplicates")
        case .collector: String(localized: "Collector")
        }
    }

    var icon: String {
        switch self {
        case .contents: "list.bullet"
        case .largest: "arrow.up.right.and.arrow.down.left"
        case .types: "square.stack.3d.up"
        case .old: "clock.arrow.circlepath"
        case .changes: "plusminus"
        case .dev: "hammer"
        case .duplicates: "doc.on.doc"
        case .collector: "tray.full"
        }
    }
}

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("", selection: $model.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Image(systemName: tab.icon).help(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Text(model.inspectorTab.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            Divider()

            Group {
                switch model.inspectorTab {
                case .contents: ContentsPanel()
                case .largest: LargestPanel()
                case .types: TypesPanel()
                case .old: OldFilesPanel()
                case .changes: ChangesPanel()
                case .dev: DevCachesPanel()
                case .duplicates: DuplicatesPanel()
                case .collector: CollectorPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ContentsPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.treeVersion
        if let focus = model.focus {
            let items = focus.children
            List(selection: selectionBinding) {
                Section {
                    ForEach(items) { node in
                        NodeRowView(node: node, total: focus.size)
                            .tag(node.id)
                            .onHover { inside in if inside { model.hover(node) } else { model.unhover(node) } }
                    }
                } header: {
                    Text(String(localized: "Items: \(Fmt.count(items.count)) · \(Fmt.size(focus.size))"))
                }
            }
            .contextMenu(forSelectionType: ObjectIdentifier.self) { ids in
                NodeMenu(node: items.first { ids.contains($0.id) })
            } primaryAction: { ids in
                if let node = items.first(where: { ids.contains($0.id) }) { model.open(node) }
            }
        }
    }

    private var selectionBinding: Binding<ObjectIdentifier?> {
        Binding {
            model.selection?.id
        } set: { id in
            model.select(model.focus?.children.first { $0.id == id })
        }
    }
}

struct CollectorPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let _ = model.treeVersion
        VStack(spacing: 0) {
            if model.collector.isEmpty {
                ContentUnavailableView(String(localized: "Collector is empty"), systemImage: "tray",
                                       description: Text(String(localized: "Add deletion candidates from the context menu or with ⌘B, then remove them all at once.")))
            } else {
                List {
                    ForEach(model.collector) { node in
                        HStack {
                            NodeRowView(node: node, total: 0, detail: node.parent?.path)
                            Button {
                                model.toggleCollector(node)
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(String(localized: "Remove from Collector"))
                        }
                        .contextMenu { NodeMenu(node: node) }
                    }
                }
                Divider()
                HStack {
                    VStack(alignment: .leading) {
                        Text(String(localized: "Frees \(Fmt.size(model.collectorTotal))")).font(.headline)
                        Text(String(localized: "Items: \(Fmt.count(model.collector.count))")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(String(localized: "Clean Up")) { model.collector.removeAll() }
                    Button(String(localized: "Move to Trash")) { model.trashCollector() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
            }
        }
    }
}

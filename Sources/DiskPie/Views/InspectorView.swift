import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case contents, collector

    var id: Self { self }

    var title: String {
        switch self {
        case .contents: "Содержимое"
        case .collector: "Сборщик"
        }
    }

    var icon: String {
        switch self {
        case .contents: "list.bullet"
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
                            .onHover { inside in if inside { model.hover(node) } }
                    }
                } header: {
                    Text("\(Fmt.count(items.count)) объектов · \(Fmt.size(focus.size))")
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
                ContentUnavailableView("Сборщик пуст", systemImage: "tray",
                                       description: Text("Добавляйте кандидатов на удаление через правую кнопку или ⌘B, а потом удалите всё разом."))
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
                            .help("Убрать из сборщика")
                        }
                        .contextMenu { NodeMenu(node: node) }
                    }
                }
                Divider()
                HStack {
                    VStack(alignment: .leading) {
                        Text("Освободится \(Fmt.size(model.collectorTotal))").font(.headline)
                        Text("\(model.collector.count) объектов").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Очистить") { model.collector.removeAll() }
                    Button("В Корзину") { model.trashCollector() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(12)
            }
        }
    }
}

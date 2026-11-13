import SwiftUI

private struct AnalysisKey: Hashable {
    let focus: ObjectIdentifier?
    let version: Int
    var extra = 0
}

/// Shows where the analysis is scoped.
private struct ScopeHeader: View {
    let focus: FileNode
    var text: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope").foregroundStyle(.secondary)
            Text(text ?? "В «\(focus.displayName)»").lineLimit(1).truncationMode(.middle)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// List of analysis results; rows hold weak refs so removed nodes drop out safely.
struct ResultList: View {
    @Environment(AppModel.self) private var model
    let rows: [ResultRow]
    let total: Int64

    var body: some View {
        List(rows) { row in
            if let node = row.ref.node {
                NodeRowView(node: node, total: total, detail: row.detail)
                    .contentShape(Rectangle())
                    .onTapGesture { model.reveal(node) }
                    .onHover { inside in if inside { model.hover(node) } else { model.unhover(node) } }
                    .contextMenu { NodeMenu(node: node) }
            }
        }
    }
}

struct LargestPanel: View {
    @Environment(AppModel.self) private var model
    @State private var showFolders = false
    @State private var rows: [ResultRow] = []

    var body: some View {
        VStack(spacing: 0) {
            if let focus = model.focus {
                ScopeHeader(focus: focus)
                Picker("", selection: $showFolders) {
                    Text("Файлы").tag(false)
                    Text("Папки").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
                ResultList(rows: rows, total: focus.size)
                    .task(id: AnalysisKey(focus: focus.id, version: model.treeVersion, extra: showFolders ? 1 : 0)) {
                        let nodes = showFolders ? Analyses.largestFolders(in: focus) : Analyses.largestFiles(in: focus)
                        rows = nodes.map { ResultRow($0) }
                    }
            }
        }
    }
}

struct TypesPanel: View {
    @Environment(AppModel.self) private var model
    @State private var stats: [CategoryStat] = []
    @State private var topRows: [FileCategory: [ResultRow]] = [:]
    @State private var selected: FileCategory?

    var body: some View {
        VStack(spacing: 0) {
            if let focus = model.focus {
                ScopeHeader(focus: focus)
                let total = max(1, stats.reduce(Int64(0)) { $0 + $1.size })
                List(selection: $selected) {
                    Section("Категории") {
                        ForEach(stats) { stat in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Image(systemName: stat.category.icon)
                                        .foregroundStyle(stat.category.color).frame(width: 18)
                                    Text(stat.category.title)
                                    Spacer()
                                    Text(Fmt.size(stat.size)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                SizeBar(fraction: Double(stat.size) / Double(total), color: stat.category.color)
                                    .padding(.leading, 24)
                                Text("\(Fmt.count(stat.count)) шт. · \(Fmt.percent(stat.size, of: total))")
                                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
                            }
                            .tag(stat.category)
                        }
                    }
                    if let selected {
                        Section("Крупнейшие: \(selected.title.lowercased())") {
                            ForEach(topRows[selected] ?? []) { row in
                                if let node = row.ref.node {
                                    NodeRowView(node: node, total: 0, detail: row.detail)
                                        .contentShape(Rectangle())
                                        .onTapGesture { model.reveal(node) }
                                        .contextMenu { NodeMenu(node: node) }
                                }
                            }
                        }
                    }
                }
                .task(id: AnalysisKey(focus: focus.id, version: model.treeVersion)) {
                    var computed = Analyses.categories(in: focus)
                    var rows: [FileCategory: [ResultRow]] = [:]
                    for index in computed.indices {
                        rows[computed[index].category] = computed[index].top.items.map { ResultRow($0.value) }
                        computed[index].top = TopK(limit: 0)
                    }
                    topRows = rows
                    stats = computed
                    if selected == nil { selected = stats.first?.category }
                }
            }
        }
    }
}

struct OldFilesPanel: View {
    @Environment(AppModel.self) private var model
    @AppStorage("oldFilesMonths") private var months = 12
    @State private var rows: [ResultRow] = []
    @State private var total: Int64 = 0
    @State private var count = 0

    var body: some View {
        VStack(spacing: 0) {
            if let focus = model.focus {
                ScopeHeader(focus: focus)
                Picker("Не менялись и не открывались дольше", selection: $months) {
                    Text("3 мес").tag(3)
                    Text("6 мес").tag(6)
                    Text("1 год").tag(12)
                    Text("2 года").tag(24)
                    Text("3 года").tag(36)
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 12)
                Text("\(Fmt.files(count)) на \(Fmt.size(total)). Дата открытия берётся из atime, macOS обновляет её не всегда.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                ResultList(rows: rows, total: 0)
                    .task(id: AnalysisKey(focus: focus.id, version: model.treeVersion, extra: months)) {
                        let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: Date()) ?? Date()
                        let result = Analyses.oldFiles(in: focus, olderThan: cutoff)
                        total = result.total
                        count = result.count
                        rows = result.files.map { node in
                            let date = Date(timeIntervalSince1970: max(node.modified, node.accessed))
                            return ResultRow(node, detail: "\(date.formatted(date: .abbreviated, time: .omitted)) · \(node.parent?.path ?? "")")
                        }
                    }
            }
        }
    }
}

struct DevCachesPanel: View {
    @Environment(AppModel.self) private var model
    @State private var artifacts: [ResultRow] = []

    var body: some View {
        let store = model.devCaches
        List {
            Section {
                ForEach(store.items) { item in
                    if item.size != nil || store.measuredAt == nil {
                        DevCacheRow(item: item)
                    }
                }
            } header: {
                HStack {
                    Text("Кэши инструментов")
                    Spacer()
                    if store.isMeasuring {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("Измерить") { store.measure() }.buttonStyle(.borderless)
                    }
                }
            } footer: {
                if store.measuredAt != nil {
                    Text("Можно очистить: \(Fmt.size(store.total)). Содержимое уходит в Корзину.")
                }
            }

            Section("Сборки и зависимости в проектах") {
                if artifacts.isEmpty {
                    Text("node_modules, Pods, .build, DerivedData и т. п. в текущем скане не найдены")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(artifacts) { row in
                    if let node = row.ref.node {
                        NodeRowView(node: node, total: 0, detail: node.parent?.path)
                            .contentShape(Rectangle())
                            .onTapGesture { model.reveal(node) }
                            .contextMenu { NodeMenu(node: node) }
                    }
                }
            }
        }
        .onAppear { if store.measuredAt == nil { store.measure() } }
        .task(id: AnalysisKey(focus: model.root?.id, version: model.treeVersion)) {
            guard let root = model.root else { return }
            artifacts = Analyses.buildArtifacts(in: root).map { ResultRow($0) }
        }
    }
}

private struct DevCacheRow: View {
    @Environment(AppModel.self) private var model
    let item: DevCacheItem

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                Text(item.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(item.size.map(Fmt.size) ?? "…").monospacedDigit().foregroundStyle(.secondary)
                if item.cleanable, (item.size ?? 0) > 0 {
                    Button("Очистить") { model.cleanContents(of: item) }
                        .controlSize(.small)
                }
            }
        }
        .contextMenu {
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
            Button("Скопировать путь") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        }
    }
}

struct DuplicatesPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var search = model.duplicates
        VStack(spacing: 0) {
            if let focus = model.focus {
                ScopeHeader(focus: focus)
                HStack {
                    Picker("От", selection: $search.minSize) {
                        Text("100 КБ").tag(Int64(100_000))
                        Text("1 МБ").tag(Int64(1_000_000))
                        Text("10 МБ").tag(Int64(10_000_000))
                        Text("100 МБ").tag(Int64(100_000_000))
                    }
                    .frame(width: 130)
                    Spacer()
                    if search.phase == .running {
                        Button("Стоп") { search.cancel() }
                    } else {
                        Button("Найти") { search.start(in: focus) }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isScanning)
                    }
                }
                .padding(.horizontal, 12)

                switch search.phase {
                case .idle:
                    ContentUnavailableView("Поиск дубликатов", systemImage: "doc.on.doc",
                                           description: Text("Сравнивает файлы одинакового размера по содержимому (SHA-256). Жёсткие ссылки не считаются дубликатами; клоны APFS могут не занимать места."))
                case .running:
                    VStack(spacing: 8) {
                        ProgressView(value: search.fraction)
                        Text(search.status).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    Spacer()
                case .done:
                    Text(search.groups.isEmpty ? "Дубликатов не найдено" :
                            "\(search.groups.count) групп, лишнего \(Fmt.size(search.totalWasted))")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                    List {
                        ForEach(search.groups) { group in
                            Section {
                                ForEach(group.paths, id: \.self) { path in
                                    DuplicateRow(path: path)
                                }
                            } header: {
                                HStack {
                                    Text("\(group.paths.count) × \(Fmt.size(group.size))")
                                    Spacer()
                                    Button("Оставить первый") {
                                        let extra = search.extraCopies(in: group)
                                        if extra.isEmpty {
                                            model.showMessage("Группа устарела", "Первая копия изменилась или удалена. Запустите поиск заново.")
                                        } else {
                                            model.trash(paths: extra)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Остальные копии — в Корзину")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct DuplicateRow: View {
    @Environment(AppModel.self) private var model
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text((path as NSString).lastPathComponent).lineLimit(1)
            Text((path as NSString).deletingLastPathComponent)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
        }
        .contentShape(Rectangle())
        .onTapGesture { if let node = model.node(atPath: path) { model.reveal(node) } }
        .contextMenu {
            Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Button("Быстрый просмотр") { model.quickLookURL = URL(fileURLWithPath: path) }
            Divider()
            Button("Переместить в Корзину", role: .destructive) { model.trash(paths: [path]) }
        }
    }
}

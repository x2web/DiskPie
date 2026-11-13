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
            Text(text ?? String(localized: "In “\(focus.displayName)”")).lineLimit(1).truncationMode(.middle)
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
                    Text(String(localized: "Files")).tag(false)
                    Text(String(localized: "Folders")).tag(true)
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
                    Section(String(localized: "Categories")) {
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
                                Text("\(Fmt.items(stat.count)) · \(Fmt.percent(stat.size, of: total))")
                                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 24)
                            }
                            .tag(stat.category)
                        }
                    }
                    if let selected {
                        Section(String(localized: "Largest: \(selected.title.lowercased())")) {
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
                Picker(String(localized: "Not modified or opened for"), selection: $months) {
                    Text(String(localized: "3 months")).tag(3)
                    Text(String(localized: "6 months")).tag(6)
                    Text(String(localized: "1 year")).tag(12)
                    Text(String(localized: "2 years")).tag(24)
                    Text(String(localized: "3 years")).tag(36)
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 12)
                Text(String(localized: "\(Fmt.files(count)), \(Fmt.size(total)). The last-opened date comes from atime, which macOS does not always update."))
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
                    Text(String(localized: "Tool caches"))
                    Spacer()
                    if store.isMeasuring {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button(String(localized: "Measure")) { store.measure() }.buttonStyle(.borderless)
                    }
                }
            } footer: {
                if store.measuredAt != nil {
                    Text(String(localized: "Cleanable: \(Fmt.size(store.total)). Contents go to the Trash."))
                }
            }

            Section(String(localized: "Builds and dependencies in projects")) {
                if artifacts.isEmpty {
                    Text(String(localized: "No node_modules, Pods, .build, DerivedData or similar in this scan"))
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
                    Button(String(localized: "Clean Up")) { model.cleanContents(of: item) }
                        .controlSize(.small)
                }
            }
        }
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
}

struct DuplicatesPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var search = model.duplicates
        VStack(spacing: 0) {
            if let focus = model.focus {
                ScopeHeader(focus: focus)
                HStack {
                    Picker(String(localized: "Min size"), selection: $search.minSize) {
                        Text(String(localized: "100 KB")).tag(Int64(100_000))
                        Text(String(localized: "1 MB")).tag(Int64(1_000_000))
                        Text(String(localized: "10 MB")).tag(Int64(10_000_000))
                        Text(String(localized: "100 MB")).tag(Int64(100_000_000))
                    }
                    .frame(width: 130)
                    Spacer()
                    if search.phase == .running {
                        Button(String(localized: "Stop")) { search.cancel() }
                    } else {
                        Button(String(localized: "Find")) { search.start(in: focus) }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isScanning)
                    }
                }
                .padding(.horizontal, 12)

                switch search.phase {
                case .idle:
                    ContentUnavailableView(String(localized: "Find duplicates"), systemImage: "doc.on.doc",
                                           description: Text(String(localized: "Compares files of equal size by content (SHA-256). Hard links are not duplicates; APFS clones may take no extra space.")))
                case .running:
                    VStack(spacing: 8) {
                        ProgressView(value: search.fraction)
                        Text(search.status).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    Spacer()
                case .done:
                    Text(search.groups.isEmpty ? String(localized: "No duplicates found") :
                            String(localized: "Groups: \(Fmt.count(search.groups.count)), reclaimable \(Fmt.size(search.totalWasted))"))
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
                                    Button(String(localized: "Keep First")) {
                                        let extra = search.extraCopies(in: group)
                                        if extra.isEmpty {
                                            model.showMessage(String(localized: "Group is out of date"), String(localized: "The first copy was changed or removed. Run the search again."))
                                        } else {
                                            model.trash(paths: extra)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .help(String(localized: "Move the other copies to the Trash"))
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
            Button(String(localized: "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            Button(String(localized: "Quick Look")) { model.quickLookURL = URL(fileURLWithPath: path) }
            Divider()
            Button(String(localized: "Move to Trash"), role: .destructive) { model.trash(paths: [path]) }
        }
    }
}

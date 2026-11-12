import SwiftUI

struct StartExtraButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.chooseFolderAndScanAsAdmin() } label: {
            Label("От администратора…", systemImage: "lock.shield")
        }
        .help("Посчитать и папки, которые читает только root. macOS спросит пароль.")
    }
}

struct RecentScansSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.recentScans.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Сохранённые сканы").font(.title3.weight(.semibold))
                VStack(spacing: 0) {
                    ForEach(model.recentScans) { meta in
                        SnapshotRow(meta: meta)
                        if meta != model.recentScans.last { Divider() }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))
            }
        }
    }
}

private struct SnapshotRow: View {
    @Environment(AppModel.self) private var model
    let meta: ScanMeta
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(meta.rootPath).lineLimit(1).truncationMode(.middle)
                Text("\(Fmt.date(meta.date)) · \(Fmt.size(meta.totalSize)) · \(Fmt.files(meta.fileCount))\(meta.partial ? " · неполный" : "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Открыть") { model.openSnapshot(meta) }
            Button("Пересканировать") { model.startScan(path: meta.rootPath) }
            Button {
                model.deleteSnapshot(meta)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Удалить снимок")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
        .onHover { hovering = $0 }
    }
}

struct ScanMenuExtras: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button("От администратора…") { model.chooseFolderAndScanAsAdmin() }
        if !model.rootPath.isEmpty {
            Button("Текущую папку от администратора") { model.scanAsAdmin(path: model.rootPath) }
        }
        if !model.recentScans.isEmpty {
            Divider()
            Menu("Сохранённые сканы") {
                ForEach(model.recentScans.prefix(15)) { meta in
                    Button("\((meta.rootPath as NSString).lastPathComponent.isEmpty ? meta.rootPath : (meta.rootPath as NSString).lastPathComponent) — \(Fmt.date(meta.date))") {
                        model.openSnapshot(meta)
                    }
                }
            }
        }
    }
}

struct ToolbarExtras: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Toggle(isOn: $model.liveUpdates) {
            Image(systemName: model.liveUpdates ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
        }
        .help(model.liveUpdates ? "Живое обновление включено" : "Обновлять при изменениях на диске")
        Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
            .help("Панель (⌘I)")
    }
}

struct StatusExtras: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let meta = model.cachedMeta {
            Label("снимок от \(Fmt.date(meta.date))", systemImage: "clock")
                .foregroundStyle(.secondary)
                .help("Данные из сохранённого скана. ⌘R — пересканировать.")
        }
        if model.liveUpdates {
            Label(model.liveChanges > 0 ? "обновлений: \(model.liveChanges)" : "слежу за изменениями",
                  systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)
        }
        if model.busyWriting {
            ProgressView().controlSize(.mini)
            Text("сохраняю снимок").foregroundStyle(.secondary)
        }
    }
}

struct SettingsExtras: View {
    @Environment(AppModel.self) private var model
    @State private var usage: Int64 = 0

    var body: some View {
        @Bindable var model = model
        Toggle("Обновлять диаграмму при изменениях на диске", isOn: $model.liveUpdates)
        LabeledContent("Сохранённые сканы") {
            HStack {
                Text("\(model.recentScans.count), \(Fmt.size(usage))").foregroundStyle(.secondary)
                Button("Показать") { NSWorkspace.shared.open(ScanStore.directory) }
                Button("Удалить все") {
                    model.deleteAllSnapshots()
                    usage = ScanStore.diskUsage
                }
            }
        }
        .onAppear { usage = ScanStore.diskUsage }
    }
}

struct ChangesPanel: View {
    @Environment(AppModel.self) private var model
    @State private var selected: ScanMeta?
    @State private var threshold: Int64 = 10_000_000
    @State private var items: [ChangeItem] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        let snapshots = model.previousSnapshots
        VStack(spacing: 0) {
            if snapshots.isEmpty {
                ContentUnavailableView("Не с чем сравнить", systemImage: "clock.arrow.2.circlepath",
                                       description: Text("После каждого скана DiskPie сохраняет снимок. Пересканируйте эту папку позже — здесь будет видно, что выросло, что появилось и что пропало."))
            } else {
                Form {
                    Picker("Сравнить со сканом", selection: $selected) {
                        ForEach(snapshots) { meta in
                            Text("\(Fmt.date(meta.date)) — \(Fmt.size(meta.totalSize))").tag(Optional(meta))
                        }
                    }
                    Picker("Порог", selection: $threshold) {
                        Text("1 МБ").tag(Int64(1_000_000))
                        Text("10 МБ").tag(Int64(10_000_000))
                        Text("100 МБ").tag(Int64(100_000_000))
                        Text("1 ГБ").tag(Int64(1_000_000_000))
                    }
                }
                .formStyle(.columns)
                .padding(12)

                if let selected, let root = model.root {
                    let delta = root.size - selected.totalSize
                    Text("Итого: \(Fmt.signedSize(delta)) с \(Fmt.date(selected.date))")
                        .font(.callout.bold())
                        .foregroundStyle(delta > 0 ? .red : .green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                }
                if loading {
                    ProgressView().padding()
                    Spacer()
                } else if let error {
                    Text(error).foregroundStyle(.red).padding()
                    Spacer()
                } else {
                    List(items) { item in
                        ChangeRow(item: item)
                    }
                }
            }
        }
        .onAppear { if selected == nil { selected = snapshots.first } }
        .task(id: "\(selected?.id ?? "")-\(threshold)-\(model.treeVersion)") { await compare() }
    }

    private func compare() async {
        guard let selected, let root = model.root else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            let previous = try await Task.detached(priority: .userInitiated) { try ScanStore.load(selected) }.value
            items = Analyses.changes(current: root, previous: previous, rootPath: model.rootPath, threshold: threshold)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ChangeRow: View {
    @Environment(AppModel.self) private var model
    let item: ChangeItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isNew ? "plus.circle.fill" : item.isGone ? "minus.circle.fill" : item.delta > 0 ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(item.delta > 0 ? .red : .green)
            VStack(alignment: .leading, spacing: 1) {
                Text((item.path as NSString).lastPathComponent).lineLimit(1)
                Text(item.isGone ? "удалено · было \(Fmt.size(item.oldSize))" :
                        item.isNew ? "новое · \((item.path as NSString).deletingLastPathComponent)" :
                        "\(Fmt.size(item.oldSize)) → \(Fmt.size(item.newSize)) · \((item.path as NSString).deletingLastPathComponent)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(Fmt.signedSize(item.delta)).monospacedDigit().foregroundStyle(item.delta > 0 ? .red : .green)
        }
        .contentShape(Rectangle())
        .onTapGesture { if let node = model.node(atPath: item.path) { model.reveal(node) } }
        .contextMenu {
            if let node = model.node(atPath: item.path) { NodeMenu(node: node) }
        }
    }
}

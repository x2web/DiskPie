import SwiftUI

struct StartExtraButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.chooseFolderAndScanAsAdmin() } label: {
            Label(String(localized: "As Administrator…"), systemImage: "lock.shield")
        }
        .help(String(localized: "Also count folders that only root can read. macOS will ask for your password."))
    }
}

struct RecentScansSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.recentScans.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "Saved Scans")).font(.title3.weight(.semibold))
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
                Text("\(Fmt.date(meta.date)) · \(Fmt.size(meta.totalSize)) · \(Fmt.files(meta.fileCount))" + (meta.partial ? String(localized: " · incomplete") : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Open")) { model.openSnapshot(meta) }
            Button(String(localized: "Rescan")) { model.startScan(path: meta.rootPath) }
            Button {
                model.deleteSnapshot(meta)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(String(localized: "Delete saved scan"))
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
        Button(String(localized: "As Administrator…")) { model.chooseFolderAndScanAsAdmin() }
        if !model.rootPath.isEmpty {
            Button(String(localized: "Current Folder as Administrator")) { model.scanAsAdmin(path: model.rootPath) }
        }
        if !model.recentScans.isEmpty {
            Divider()
            Menu(String(localized: "Saved Scans")) {
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
        .help(model.liveUpdates ? String(localized: "Live updates are on") : String(localized: "Update when files change on disk"))
        Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
            .help(String(localized: "Inspector (⌘I)"))
    }
}

struct StatusExtras: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let meta = model.cachedMeta {
            Label(String(localized: "saved scan from \(Fmt.date(meta.date))"), systemImage: "clock")
                .foregroundStyle(.secondary)
                .help(String(localized: "Data from a saved scan. Press ⌘R to rescan."))
        }
        if model.liveUpdates {
            Label(model.liveChanges > 0 ? String(localized: "updates: \(Fmt.count(model.liveChanges))") : String(localized: "watching for changes"),
                  systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)
        }
        if model.busyWriting {
            ProgressView().controlSize(.mini)
            Text(String(localized: "saving scan")).foregroundStyle(.secondary)
        }
    }
}

struct SettingsExtras: View {
    @Environment(AppModel.self) private var model
    @State private var usage: Int64 = 0

    var body: some View {
        @Bindable var model = model
        Toggle(String(localized: "Update the chart when files change on disk"), isOn: $model.liveUpdates)
        LabeledContent(String(localized: "Saved Scans")) {
            HStack {
                Text("\(model.recentScans.count), \(Fmt.size(usage))").foregroundStyle(.secondary)
                Button(String(localized: "Show")) { NSWorkspace.shared.open(ScanStore.directory) }
                Button(String(localized: "Delete All")) {
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
                ContentUnavailableView(String(localized: "Nothing to compare with"), systemImage: "clock.arrow.2.circlepath",
                                       description: Text(String(localized: "DiskPie saves a snapshot after every scan. Rescan this folder later to see what grew, what appeared and what disappeared.")))
            } else {
                Form {
                    Picker(String(localized: "Compare with"), selection: $selected) {
                        ForEach(snapshots) { meta in
                            Text("\(Fmt.date(meta.date)) — \(Fmt.size(meta.totalSize))").tag(Optional(meta))
                        }
                    }
                    Picker(String(localized: "Threshold"), selection: $threshold) {
                        Text(String(localized: "1 MB")).tag(Int64(1_000_000))
                        Text(String(localized: "10 MB")).tag(Int64(10_000_000))
                        Text(String(localized: "100 MB")).tag(Int64(100_000_000))
                        Text(String(localized: "1 GB")).tag(Int64(1_000_000_000))
                    }
                }
                .formStyle(.columns)
                .padding(12)

                if let selected, let root = model.root {
                    let delta = root.size - selected.totalSize
                    Text(String(localized: "Net change: \(Fmt.signedSize(delta)) since \(Fmt.date(selected.date))"))
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
                Text(item.isGone ? String(localized: "removed · was \(Fmt.size(item.oldSize))") :
                        item.isNew ? String(localized: "new · \((item.path as NSString).deletingLastPathComponent)") :
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

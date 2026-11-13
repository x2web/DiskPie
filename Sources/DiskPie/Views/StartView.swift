import SwiftUI

struct StartView: View {
    @Environment(AppModel.self) private var model
    @State private var volumes: [VolumeInfo] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.linearGradient(colors: [.purple, .blue], startPoint: .top, endPoint: .bottom))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DiskPie").font(.largeTitle.bold())
                        Text(String(localized: "What is taking up your disk")).foregroundStyle(.secondary)
                    }
                }

                if !model.hasFullDiskAccess { AccessBanner() }

                section(String(localized: "Disks")) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                        ForEach(volumes) { volume in
                            VolumeCard(volume: volume) { model.startScan(path: volume.path) }
                        }
                    }
                }

                section(String(localized: "Folders")) {
                    HStack(spacing: 10) {
                        Button { model.startScan(path: NSHomeDirectory()) } label: {
                            Label(String(localized: "Home Folder"), systemImage: "house")
                        }
                        Button { model.chooseFolderAndScan() } label: {
                            Label(String(localized: "Choose Folder…"), systemImage: "folder")
                        }
                        StartExtraButtons()
                    }
                    .controlSize(.large)
                    Text(String(localized: "You can also drag a folder onto this window.")).font(.callout).foregroundStyle(.secondary)
                }

                RecentScansSection()
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { volumes = DiskAccess.volumes() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumes = DiskAccess.volumes()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumes = DiskAccess.volumes()
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            content()
        }
    }
}

struct VolumeCard: View {
    let volume: VolumeInfo
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: volume.path))
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(volume.name).font(.headline).lineLimit(1)
                        if volume.isNetwork { Image(systemName: "network").foregroundStyle(.secondary) }
                        else if volume.isRemovable || !volume.isInternal { Image(systemName: "externaldrive").foregroundStyle(.secondary) }
                    }
                    SizeBar(fraction: volume.fraction, color: volume.fraction > 0.9 ? .red : volume.fraction > 0.75 ? .orange : .accentColor)
                    Text(String(localized: "\(Fmt.size(volume.used)) used of \(Fmt.size(volume.total)) · \(Fmt.size(volume.available)) free"))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary)))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(volume.path)
    }
}



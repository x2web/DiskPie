import SwiftUI

struct AccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "No Full Disk Access")).font(.headline)
                Text(String(localized: "Mail, Messages, Safari, app containers and parts of Library will not be counted."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "How to Enable")) { model.showOnboarding = true }
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AccessOnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: model.hasFullDiskAccess ? "checkmark.shield.fill" : "externaldrive.badge.questionmark")
                    .font(.system(size: 34))
                    .foregroundStyle(model.hasFullDiskAccess ? .green : .orange)
                VStack(alignment: .leading) {
                    Text(String(localized: "Full Disk Access")).font(.title2.bold())
                    Text(model.hasFullDiskAccess ? String(localized: "Enabled: DiskPie can see every folder.") : String(localized: "Currently off"))
                        .foregroundStyle(.secondary)
                }
            }

            Text(String(localized: "macOS does not let apps read protected folders without permission. Scanning still works without it, but those folders show up as “no access” and the total comes out lower than it really is."))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                step(1, String(localized: "Open System Settings → Privacy & Security → Full Disk Access."))
                step(2, String(localized: "Click “+” and choose DiskPie, or drag the app into the list."))
                step(3, String(localized: "Turn on the switch next to DiskPie and come back here."))
            }

            Text(String(localized: "Even with Full Disk Access some system folders are readable by root only. For those, use “Scan as Administrator…” in the File menu."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(String(localized: "Open Settings")) { DiskAccess.openFullDiskAccessSettings() }
                    .keyboardShortcut(.defaultAction)
                Button(String(localized: "Show DiskPie in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Spacer()
                Button(String(localized: "Check Again")) { model.refreshAccessStatus() }
                Button(String(localized: "Done")) { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.callout.bold()).frame(width: 22, height: 22)
                .background(Circle().fill(.quaternary))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

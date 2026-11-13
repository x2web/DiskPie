import SwiftUI

struct NodeMenu: View {
    @Environment(AppModel.self) private var model
    let node: FileNode?

    var body: some View {
        if let node {
            Text("\(node.displayName) — \(Fmt.size(node.size))")
            Divider()
            if node.kind == .hidden {
                Text(String(localized: "APFS snapshots, purgeable space, system volumes"))
            } else {
                if node.isContainer && node !== model.focus {
                    Button(String(localized: "Go Into")) { model.enter(node) }
                }
                Button(String(localized: "Open")) { model.open(node) }
                Button(String(localized: "Show in Finder")) { model.revealInFinder(node) }
                Button(String(localized: "Quick Look")) { model.quickLook(node) }
                Button(String(localized: "Copy Path")) { model.copyPath(node) }
                if node.isActionable {
                    Divider()
                    Button(model.isInCollector(node) ? String(localized: "Remove from Collector") : String(localized: "Add to Collector")) {
                        model.toggleCollector(node)
                    }
                }
                if node.isContainer {
                    Button(String(localized: "Rescan Folder")) { model.rescan(node) }
                        .disabled(model.isScanning)
                }
                if node.isActionable {
                    Divider()
                    Button(String(localized: "Move to Trash"), role: .destructive) { model.trash([node]) }
                    Button(String(localized: "Delete Permanently…"), role: .destructive) { model.trash([node], permanently: true) }
                }
            }
        }
    }
}

struct NodeIcon: View {
    let node: FileNode

    var body: some View {
        Image(systemName: Palette.icon(for: node))
            .foregroundStyle(Palette.iconColor(for: node))
            .frame(width: 18)
    }
}

struct SizeBar: View {
    let fraction: Double
    var color: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color.opacity(0.8))
                    .frame(width: max(2, proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 4)
    }
}

/// Row for any list of nodes: icon, name, optional detail, size and share bar.
struct NodeRowView: View {
    let node: FileNode
    let total: Int64
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                NodeIcon(node: node)
                VStack(alignment: .leading, spacing: 1) {
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 8)
                Text(Fmt.size(node.size)).monospacedDigit().foregroundStyle(.secondary)
            }
            if total > 0 {
                SizeBar(fraction: Double(node.size) / Double(total), color: Palette.iconColor(for: node))
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
    }
}

import SwiftUI

enum Palette {
    static func color(hue: Double, depth: Int, node: FileNode?, highlighted: Bool = false) -> Color {
        guard let node else { return aggregate }
        switch node.kind {
        case .hidden: return hidden
        case .inaccessible: return Color(white: 0.45)
        default: break
        }
        let level = Double(max(0, depth - 1))
        let isFile = !node.isContainer
        let saturation = max(0.18, (isFile ? 0.32 : 0.6) - level * 0.06)
        let brightness = min(0.97, (isFile ? 0.9 : 0.74) + level * 0.045 + (highlighted ? 0.12 : 0))
        let wrapped = hue - floor(hue)
        return Color(hue: wrapped, saturation: saturation, brightness: brightness)
    }

    static let aggregate = Color(white: 0.62).opacity(0.55)
    static let hidden = Color(white: 0.5).opacity(0.75)
    static let separator = Color(nsColor: .windowBackgroundColor)

    static func icon(for node: FileNode) -> String {
        if node.isPending { return "hourglass" }
        switch node.kind {
        case .directory: return "folder.fill"
        case .package: return node.fileExtension == "app" ? "app.fill" : "shippingbox.fill"
        case .symlink: return "arrow.turn.up.right"
        case .inaccessible: return "lock.fill"
        case .hidden: return "eye.slash.fill"
        case .file: return FileCategory.of(node).icon
        }
    }

    static func iconColor(for node: FileNode) -> Color {
        switch node.kind {
        case .directory: return .accentColor
        case .package: return .purple
        case .inaccessible, .hidden: return .secondary
        default: return FileCategory.of(node).color
        }
    }
}

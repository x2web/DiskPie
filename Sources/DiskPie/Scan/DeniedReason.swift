import Darwin
import Foundation

/// Why a folder could not be read, and whether anything in the app can help.
enum DeniedReason: Int, CaseIterable, Identifiable {
    case permissions, systemProtection, missing, other

    var id: Self { self }

    init(code: Int32) {
        switch code {
        case EACCES: self = .permissions
        case EPERM: self = .systemProtection
        case ENOENT, ENOTDIR: self = .missing
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .permissions: String(localized: "Permissions (root or another owner only)")
        case .systemProtection: String(localized: "macOS protection: SIP, data vaults, policies")
        case .missing: String(localized: "Disappeared during the scan")
        case .other: String(localized: "Other errors")
        }
    }

    var hint: String {
        switch self {
        case .permissions: String(localized: "Readable with “Scan as Administrator…”.")
        case .systemProtection: String(localized: "Blocked by the kernel even for root with Full Disk Access: system-protected folders, system app containers, managed profile (MDM) data. This cannot and should not be bypassed.")
        case .missing: String(localized: "Temporary files removed between listing a folder and entering it.")
        case .other: String(localized: "File system read errors.")
        }
    }

    struct Group: Identifiable {
        var id: DeniedReason { reason }
        let reason: DeniedReason
        let paths: [DeniedPath]
    }

    static func group(_ paths: [DeniedPath]) -> [Group] {
        Dictionary(grouping: paths) { DeniedReason(code: $0.code) }
            .map { Group(reason: $0.key, paths: $0.value.sorted { $0.path < $1.path }) }
            .sorted { $0.reason.rawValue < $1.reason.rawValue }
    }
}

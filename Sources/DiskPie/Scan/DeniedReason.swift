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
        case .permissions: "Права доступа (только root или другой владелец)"
        case .systemProtection: "Защита macOS: SIP, хранилища данных, политики"
        case .missing: "Исчезли во время скана"
        case .other: "Другие ошибки"
        }
    }

    var hint: String {
        switch self {
        case .permissions: "Прочитаются при «Сканировать от администратора…»."
        case .systemProtection: "Закрыты ядром даже для root с полным доступом к диску: защищённые системой папки, контейнеры системных приложений, данные управляемых профилей (MDM). Обойти нельзя и не нужно."
        case .missing: "Временные файлы, удалённые между чтением каталога и входом в него."
        case .other: "Ошибки чтения файловой системы."
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

import Foundation

struct DevCacheItem: Identifiable {
    var id: String { path }
    let title: String
    let path: String
    let note: String
    /// false: only shown, cleaning is left to the owning tool.
    let cleanable: Bool
    var size: Int64?
}

@MainActor @Observable
final class DevCacheStore {
    var items: [DevCacheItem] = DevCacheStore.presets()
    var isMeasuring = false
    var measuredAt: Date?

    var total: Int64 { items.filter(\.cleanable).compactMap(\.size).reduce(0, +) }

    static func presets() -> [DevCacheItem] {
        let home = NSHomeDirectory()
        func item(_ title: String, _ path: String, _ note: String, cleanable: Bool = true) -> DevCacheItem {
            DevCacheItem(title: title, path: path.replacingOccurrences(of: "~", with: home), note: note, cleanable: cleanable)
        }
        return [
            item("Xcode DerivedData", "~/Library/Developer/Xcode/DerivedData", "Промежуточные сборки, Xcode пересоберёт"),
            item("Xcode Archives", "~/Library/Developer/Xcode/Archives", "Архивы релизов с dSYM — удаляйте старые осознанно"),
            item("iOS DeviceSupport", "~/Library/Developer/Xcode/iOS DeviceSupport", "Символы устройств, скачаются при подключении"),
            item("watchOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport", "Символы часов"),
            item("Кэш Xcode", "~/Library/Caches/com.apple.dt.Xcode", "Кэш индексов и загрузок"),
            item("Кэши симуляторов", "~/Library/Developer/CoreSimulator/Caches", "Кэш dyld и рантаймов"),
            item("Данные симуляторов", "~/Library/Developer/CoreSimulator/Devices",
                 "Приложения и логины на симуляторах. Чистить через Xcode или `xcrun simctl delete unavailable`", cleanable: false),
            item("Рантаймы симуляторов", "/Library/Developer/CoreSimulator/Volumes",
                 "Управляются Xcode → Settings → Platforms", cleanable: false),
            item("Swift PM", "~/Library/Caches/org.swift.swiftpm", "Кэш пакетов, скачается заново"),
            item("CocoaPods", "~/Library/Caches/CocoaPods", "Кэш подов"),
            item("Carthage", "~/Library/Caches/org.carthage.CarthageKit", "Кэш Carthage"),
            item("Gradle", "~/.gradle/caches", "Кэш зависимостей и сборок Gradle"),
            item("Android SDK", "~/Library/Android/sdk", "Управляется Android Studio → SDK Manager", cleanable: false),
            item("npm", "~/.npm/_cacache", "Кэш npm"),
            item("Yarn", "~/Library/Caches/Yarn", "Кэш Yarn"),
            item("pnpm", "~/Library/pnpm/store", "Хранилище pnpm"),
            item("pip", "~/Library/Caches/pip", "Кэш pip"),
            item("Homebrew", "~/Library/Caches/Homebrew", "Скачанные бутылки, `brew cleanup` делает то же"),
            item("Docker", "~/Library/Containers/com.docker.docker/Data/vms", "Диск Docker — чистить через `docker system prune`", cleanable: false),
            item("Логи", "~/Library/Logs", "Логи приложений"),
            item("Кэши приложений", "~/Library/Caches", "Общие кэши; приложения пересоздадут их"),
        ]
    }

    func measure() {
        guard !isMeasuring else { return }
        isMeasuring = true
        let paths = items.map(\.path)
        Task.detached(priority: .utility) { [self] in
            var sizes: [String: Int64] = [:]
            await withTaskGroup(of: (String, Int64?).self) { group in
                for path in paths {
                    group.addTask {
                        guard FileManager.default.fileExists(atPath: path) else { return (path, nil) }
                        let node = Scanner.scan(path: path, shallow: false, ctx: ScanContext(skipPaths: []))
                        return (path, node.kind == .inaccessible && node.size == 0 ? nil : node.size)
                    }
                }
                for await (path, size) in group { sizes[path] = size }
            }
            let measured = sizes
            await MainActor.run {
                for index in self.items.indices { self.items[index].size = measured[self.items[index].path] ?? nil }
                self.items.sort { ($0.size ?? -1) > ($1.size ?? -1) }
                self.isMeasuring = false
                self.measuredAt = Date()
            }
        }
    }
}

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
            item("Xcode DerivedData", "~/Library/Developer/Xcode/DerivedData", String(localized: "Intermediate builds; Xcode rebuilds them")),
            item("Xcode Archives", "~/Library/Developer/Xcode/Archives", String(localized: "Release archives with dSYMs; remove old ones deliberately")),
            item("iOS DeviceSupport", "~/Library/Developer/Xcode/iOS DeviceSupport", String(localized: "Device symbols; downloaded again when a device connects")),
            item("watchOS DeviceSupport", "~/Library/Developer/Xcode/watchOS DeviceSupport", String(localized: "Watch symbols")),
            item(String(localized: "Xcode cache"), "~/Library/Caches/com.apple.dt.Xcode", String(localized: "Index and download cache")),
            item(String(localized: "Simulator caches"), "~/Library/Developer/CoreSimulator/Caches", String(localized: "dyld and runtime cache")),
            item(String(localized: "Simulator data"), "~/Library/Developer/CoreSimulator/Devices",
                 String(localized: "Apps and sign-ins on simulators. Clean up in Xcode or with `xcrun simctl delete unavailable`"), cleanable: false),
            item(String(localized: "Simulator runtimes"), "/Library/Developer/CoreSimulator/Volumes",
                 String(localized: "Managed in Xcode → Settings → Platforms"), cleanable: false),
            item("Swift PM", "~/Library/Caches/org.swift.swiftpm", String(localized: "Package cache; downloaded again")),
            item("CocoaPods", "~/Library/Caches/CocoaPods", String(localized: "Pods cache")),
            item("Carthage", "~/Library/Caches/org.carthage.CarthageKit", String(localized: "Carthage cache")),
            item("Gradle", "~/.gradle/caches", String(localized: "Gradle dependency and build cache")),
            item("Android SDK", "~/Library/Android/sdk", String(localized: "Managed in Android Studio → SDK Manager"), cleanable: false),
            item("npm", "~/.npm/_cacache", String(localized: "npm cache")),
            item("Yarn", "~/Library/Caches/Yarn", String(localized: "Yarn cache")),
            item("pnpm", "~/Library/pnpm/store", String(localized: "pnpm store")),
            item("pip", "~/Library/Caches/pip", String(localized: "pip cache")),
            item("Homebrew", "~/Library/Caches/Homebrew", String(localized: "Downloaded bottles; same as `brew cleanup`")),
            item("Docker", "~/Library/Containers/com.docker.docker/Data/vms", String(localized: "Docker disk; clean up with `docker system prune`"), cleanable: false),
            item(String(localized: "Logs"), "~/Library/Logs", String(localized: "App logs")),
            item(String(localized: "App caches"), "~/Library/Caches", String(localized: "Shared caches; apps recreate them")),
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

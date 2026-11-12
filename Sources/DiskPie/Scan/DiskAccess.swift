import AppKit
import Darwin

struct VolumeInfo: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let total: Int64
    let available: Int64
    let isInternal: Bool
    let isRemovable: Bool
    let isNetwork: Bool

    var used: Int64 { max(0, total - available) }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

enum DiskAccess {
    static let dataVolume = "/System/Volumes/Data"

    /// TCC.db is readable only with Full Disk Access; reading it never triggers a prompt.
    static func hasFullDiskAccess() -> Bool {
        let probes = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db",
        ]
        for probe in probes {
            let fd = open(probe, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
        }
        return false
    }

    static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    static func mountPoints() -> [String] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        return (0..<Int(count)).map { index in
            var entry = buffer[index]
            return withUnsafeBytes(of: &entry.f_mntonname) { raw in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
        }
    }

    /// Other volumes mounted inside the scanned tree. Firmlinks from `/` already expose the data volume,
    /// so skipping its mount point avoids counting it twice.
    static func skipPaths(forRoot root: String) -> Set<String> {
        Set(mountPoints().filter { $0 != root && $0 != "/" })
    }

    static func isVolumeRoot(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let volume = try? url.resourceValues(forKeys: [.volumeURLKey]).volume else { return false }
        return volume.standardizedFileURL.path == url.standardizedFileURL.path
    }

    static func volumeUsage(path: String) -> (total: Int64, used: Int64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacity else { return nil }
        return (Int64(total), Int64(total - available))
    }

    static func volumeName(for path: String) -> String? {
        try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeNameKey]).volumeName
    }

    static func volumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsLocalKey,
            .volumeIsBrowsableKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  v.volumeIsBrowsable ?? true,
                  let total = v.volumeTotalCapacity, total > 0 else { return nil }
            let available = v.volumeAvailableCapacityForImportantUsage ?? Int64(v.volumeAvailableCapacity ?? 0)
            return VolumeInfo(
                name: v.volumeName ?? url.lastPathComponent,
                path: url.path,
                total: Int64(total),
                available: available,
                isInternal: v.volumeIsInternal ?? false,
                isRemovable: v.volumeIsRemovable ?? false,
                isNetwork: !(v.volumeIsLocal ?? true)
            )
        }
    }

    /// Maps data-volume paths onto the firmlinked paths a `/` scan uses.
    static func normalize(_ path: String) -> String {
        if path.hasPrefix(dataVolume + "/") { return String(path.dropFirst(dataVolume.count)) }
        return path
    }

    static func isProtected(_ rawPath: String) -> Bool {
        let path = normalize(rawPath)
        let home = NSHomeDirectory()
        let exact: Set<String> = [
            "/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/private", "/private/var",
            "/private/etc", "/private/tmp", "/usr", "/bin", "/sbin", "/opt", "/cores", "/dev", dataVolume,
            home, home + "/Library", home + "/Desktop", home + "/Documents", home + "/Downloads",
            home + "/Pictures", home + "/Movies", home + "/Music", home + "/Applications",
        ]
        if exact.contains(path) { return true }
        if path.hasPrefix("/usr/local/") { return false }
        let prefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/private/var/db/", "/Library/Apple/"]
        return prefixes.contains { path.hasPrefix($0) }
    }
}

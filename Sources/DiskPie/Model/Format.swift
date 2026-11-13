import Foundation

enum Fmt {
    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func signedSize(_ bytes: Int64) -> String {
        (bytes >= 0 ? "+" : "−") + size(abs(bytes))
    }

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    static func count(_ n: Int) -> String {
        countFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func percent(_ part: Int64, of total: Int64) -> String {
        guard total > 0 else { return "—" }
        let value = Double(part) / Double(total)
        if value < 0.001 { return "<" + percentFormatter.string(from: 0.001)! }
        return percentFormatter.string(from: NSNumber(value: value)) ?? ""
    }

    private static let percentFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.minimumFractionDigits = 1
        f.maximumFractionDigits = 1
        return f
    }()

    static func files(_ n: Int) -> String {
        guard Lang.isRussian else { return "\(count(n)) \(n == 1 ? "file" : "files")" }
        let mod10 = n % 10, mod100 = n % 100
        let word: String
        if mod10 == 1 && mod100 != 11 { word = "файл" }
        else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "файла" }
        else { word = "файлов" }
        return "\(count(n)) \(word)"
    }

    static func items(_ n: Int) -> String {
        Lang.isRussian ? "\(count(n)) шт." : "\(count(n)) \(n == 1 ? "item" : "items")"
    }

    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = t < 60 ? [.second] : [.minute, .second]
        if t < 60 {
            let seconds = NumberFormatter.localizedString(from: NSNumber(value: (t * 10).rounded() / 10), number: .decimal)
            return String(localized: "\(seconds) s")
        }
        return f.string(from: t) ?? ""
    }

    static func date(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }

    static func relativeDate(_ d: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }
}

/// UI language chosen by macOS for this app (from the bundled .lproj folders).
enum Lang {
    static let isRussian = Bundle.main.preferredLocalizations.first?.hasPrefix("ru") ?? false
}

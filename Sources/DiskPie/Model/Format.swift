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
        let value = Double(part) / Double(total) * 100
        return value < 0.1 ? "<0,1 %" : String(format: "%.1f %%", value).replacingOccurrences(of: ".", with: ",")
    }

    static func files(_ n: Int) -> String {
        let mod10 = n % 10, mod100 = n % 100
        let word: String
        if mod10 == 1 && mod100 != 11 { word = "файл" }
        else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "файла" }
        else { word = "файлов" }
        return "\(count(n)) \(word)"
    }

    static func duration(_ t: TimeInterval) -> String {
        t < 60 ? String(format: "%.1f с", t).replacingOccurrences(of: ".", with: ",")
               : "\(Int(t) / 60) мин \(Int(t) % 60) с"
    }

    static func date(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }

    static func relativeDate(_ d: Date) -> String {
        RelativeDateTimeFormatter().localizedString(for: d, relativeTo: Date())
    }
}

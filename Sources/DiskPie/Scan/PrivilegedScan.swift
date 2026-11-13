import Foundation

/// Scans as root by re-launching this binary in CLI mode through the standard administrator prompt.
/// No helper daemon is installed; the elevated process lives only for the duration of the scan.
enum PrivilegedScan {
    enum Failure: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: String(localized: "Cancelled")
            case .failed(let text): text
            }
        }
    }

    /// `DiskPie --scan <path> --out <file>`: full scan written as a snapshot readable by the user.
    static func runCLI(arguments: [String]) -> Int32 {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), arguments.count > i + 1 else { return nil }
            return arguments[i + 1]
        }
        guard let path = value("--scan"), let out = value("--out") else {
            FileHandle.standardError.write(Data("usage: --scan <path> --out <file>\n".utf8))
            return 2
        }
        let ctx = ScanContext(skipPaths: DiskAccess.skipPaths(forRoot: path))
        let root = Scanner.scan(path: path, shallow: false, ctx: ctx)
        do {
            try ScanArchive.write(root, rootPath: path, date: Date(), partial: false, to: URL(fileURLWithPath: out))
            chmod(out, 0o644)
            let p = ctx.snapshot()
            print("\(p.files) files, \(p.inaccessible) inaccessible")
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }

    static func run(path: String, box: ProcessBox) async throws -> (FileNode, Int) {
        guard let executable = Bundle.main.executablePath else { throw Failure.failed(String(localized: "Executable not found")) }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("diskpie-\(UUID().uuidString).dpscan").path
        defer { try? FileManager.default.removeItem(atPath: out) }

        let command = "\(shellQuote(executable)) --scan \(shellQuote(path)) --out \(shellQuote(out))"
        let prompt = String(localized: "DiskPie wants to scan “\(path)” with administrator privileges.")
        let script = "do shell script \"\(appleScriptEscape(command))\" with prompt \"\(appleScriptEscape(prompt))\" with administrator privileges"

        let (status, output) = try await runProcess("/usr/bin/osascript", ["-e", script], box: box)
        if status != 0 {
            if output.contains("-128") { throw Failure.cancelled }
            throw Failure.failed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let numbers = output.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let inaccessible = numbers.count >= 2 ? numbers[1] : 0
        let data = try Data(contentsOf: URL(fileURLWithPath: out))
        return (try ScanArchive.decode(data).1, inaccessible)
    }

    private static func runProcess(_ tool: String, _ args: [String], box: ProcessBox) async throws -> (Int32, String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
                box.set(process)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Lets the UI stop the administrator prompt or scan while it runs.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func set(_ process: Process) {
        let terminateNow = lock.withLock { () -> Bool in
            self.process = process
            return cancelled
        }
        if terminateNow { process.terminate() }
    }

    func terminate() {
        let process = lock.withLock { () -> Process? in
            cancelled = true
            return self.process
        }
        if let process, process.isRunning { process.terminate() }
    }
}

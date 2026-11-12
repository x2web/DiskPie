import Foundation

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--render") {
            exit(MainActor.assumeIsolated { DebugRender.run(arguments: arguments) })
        }
        if arguments.contains("--scan") { exit(PrivilegedScan.runCLI(arguments: arguments)) }
        if arguments.contains("--analyze") { exit(DebugAnalyze.run(arguments: arguments)) }
        DiskPieApp.main()
    }
}

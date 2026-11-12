import Foundation

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--render") {
            exit(MainActor.assumeIsolated { DebugRender.run(arguments: arguments) })
        }
        DiskPieApp.main()
    }
}

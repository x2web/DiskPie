import SwiftUI

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(String(localized: "Open Folder…")) { model.chooseFolderAndScan() }
                .keyboardShortcut("o")
            Button(String(localized: "Scan Home Folder")) { model.startScan(path: NSHomeDirectory()) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button(String(localized: "Scan Startup Disk")) { model.startScan(path: "/") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button(String(localized: "Scan as Administrator…")) { model.chooseFolderAndScanAsAdmin() }
            Divider()
            Button(String(localized: "Rescan")) { model.rescanAll() }
                .keyboardShortcut("r")
            Button(String(localized: "Stop Scanning")) { model.cancelScan() }
                .keyboardShortcut(".")
            Button(String(localized: "Close Scan")) { model.closeScan() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandMenu(String(localized: "Navigate")) {
            Button(String(localized: "Enclosing Folder")) { model.goUp() }
                .keyboardShortcut(.escape, modifiers: [])
            Button(String(localized: "Scan Root")) { model.goToRoot() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
            Button(String(localized: "Back")) { model.goBack() }
                .keyboardShortcut("[")
            Button(String(localized: "Forward")) { model.goForward() }
                .keyboardShortcut("]")
            Divider()
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) { model.viewMode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Button(String(localized: "Show/Hide Inspector")) { model.showInspector.toggle() }
                .keyboardShortcut("i")
        }

        CommandMenu(String(localized: "Item")) {
            Button(String(localized: "Open")) { if let n = model.actionTarget { model.open(n) } }
                .keyboardShortcut(.downArrow)
            Button(String(localized: "Quick Look")) { model.quickLook(model.actionTarget) }
                .keyboardShortcut(.space, modifiers: [])
            Button(String(localized: "Show in Finder")) { if let n = model.actionTarget { model.revealInFinder(n) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button(String(localized: "Copy Path")) { if let n = model.actionTarget { model.copyPath(n) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button(String(localized: "Add to Collector")) { if let n = model.actionTarget { model.toggleCollector(n) } }
                .keyboardShortcut("b")
            Divider()
            Button(String(localized: "Move to Trash")) { if let n = model.deleteTarget { model.trash([n]) } }
                .keyboardShortcut(.delete)
            Button(String(localized: "Delete Permanently…")) { if let n = model.deleteTarget { model.trash([n], permanently: true) } }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
        }
    }
}

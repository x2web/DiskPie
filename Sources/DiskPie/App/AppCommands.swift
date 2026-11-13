import SwiftUI

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Открыть папку…") { model.chooseFolderAndScan() }
                .keyboardShortcut("o")
            Button("Сканировать домашнюю папку") { model.startScan(path: NSHomeDirectory()) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Сканировать загрузочный диск") { model.startScan(path: "/") }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Сканировать от администратора…") { model.chooseFolderAndScanAsAdmin() }
            Divider()
            Button("Пересканировать") { model.rescanAll() }
                .keyboardShortcut("r")
            Button("Остановить сканирование") { model.cancelScan() }
                .keyboardShortcut(".")
            Button("Закрыть скан") { model.closeScan() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }

        CommandMenu("Навигация") {
            Button("Наверх") { model.goUp() }
                .keyboardShortcut(.escape, modifiers: [])
            Button("К корню скана") { model.goToRoot() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
            Button("Назад") { model.goBack() }
                .keyboardShortcut("[")
            Button("Вперёд") { model.goForward() }
                .keyboardShortcut("]")
            Divider()
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) { model.viewMode = mode }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Button("Показать/скрыть панель") { model.showInspector.toggle() }
                .keyboardShortcut("i")
        }

        CommandMenu("Объект") {
            Button("Открыть") { if let n = model.actionTarget { model.open(n) } }
                .keyboardShortcut(.downArrow)
            Button("Быстрый просмотр") { model.quickLook(model.actionTarget) }
                .keyboardShortcut(.space, modifiers: [])
            Button("Показать в Finder") { if let n = model.actionTarget { model.revealInFinder(n) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Скопировать путь") { if let n = model.actionTarget { model.copyPath(n) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Добавить в сборщик") { if let n = model.actionTarget { model.toggleCollector(n) } }
                .keyboardShortcut("b")
            Divider()
            Button("Переместить в Корзину") { if let n = model.deleteTarget { model.trash([n]) } }
                .keyboardShortcut(.delete)
            Button("Удалить безвозвратно…") { if let n = model.deleteTarget { model.trash([n], permanently: true) } }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
        }
    }
}

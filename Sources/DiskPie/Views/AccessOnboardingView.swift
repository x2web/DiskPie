import SwiftUI

struct AccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Нет полного доступа к диску").font(.headline)
                Text("Почта, Сообщения, Safari, контейнеры приложений и часть Library не будут посчитаны.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Как включить") { model.showOnboarding = true }
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct AccessOnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: model.hasFullDiskAccess ? "checkmark.shield.fill" : "externaldrive.badge.questionmark")
                    .font(.system(size: 34))
                    .foregroundStyle(model.hasFullDiskAccess ? .green : .orange)
                VStack(alignment: .leading) {
                    Text("Доступ ко всему диску").font(.title2.bold())
                    Text(model.hasFullDiskAccess ? "Включён — DiskPie видит все папки." : "Сейчас выключен")
                        .foregroundStyle(.secondary)
                }
            }

            Text("macOS не даёт приложениям читать защищённые папки без разрешения. Без него сканирование работает, но такие папки отображаются как «нет доступа», а сумма получается меньше реальной.")
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                step(1, "Откройте Системные настройки → Конфиденциальность и безопасность → Полный доступ к диску.")
                step(2, "Нажмите «+» и выберите DiskPie, или перетащите приложение в список.")
                step(3, "Включите переключатель напротив DiskPie и вернитесь сюда.")
            }

            Text("Даже с полным доступом часть системных папок читает только root. Для них есть «Сканировать от администратора…» в меню «Файл».")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Открыть настройки") { DiskAccess.openFullDiskAccessSettings() }
                    .keyboardShortcut(.defaultAction)
                Button("Показать DiskPie в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                }
                Spacer()
                Button("Проверить") { model.refreshAccessStatus() }
                Button("Готово") { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.callout.bold()).frame(width: 22, height: 22)
                .background(Circle().fill(.quaternary))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

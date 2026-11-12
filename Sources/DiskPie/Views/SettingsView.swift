import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Stepper("Колец в диаграмме: \(model.ringDepth)", value: $model.ringDepth, in: 3...9)
            LabeledContent("Полный доступ к диску") {
                HStack {
                    Text(model.hasFullDiskAccess ? "включён" : "выключен")
                        .foregroundStyle(model.hasFullDiskAccess ? .green : .orange)
                    Button("Настроить…") { model.showOnboarding = true }
                }
            }
            SettingsExtras()
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

/// Filled in by later features.
struct SettingsExtras: View {
    var body: some View { EmptyView() }
}

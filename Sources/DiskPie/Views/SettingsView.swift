import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Stepper(String(localized: "Rings in the chart: \(Fmt.count(model.ringDepth))"), value: $model.ringDepth, in: 3...9)
            LabeledContent(String(localized: "Full Disk Access")) {
                HStack {
                    Text(model.hasFullDiskAccess ? String(localized: "on") : String(localized: "off"))
                        .foregroundStyle(model.hasFullDiskAccess ? .green : .orange)
                    Button(String(localized: "Set Up…")) { model.showOnboarding = true }
                }
            }
            SettingsExtras()
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}


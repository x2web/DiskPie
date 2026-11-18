import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Stepper(String(localized: "Rings in the chart: \(Fmt.count(model.ringDepth))"), value: $model.ringDepth, in: 3...9)
            Toggle(isOn: $model.countsClones) {
                Text(String(localized: "Count data shared by APFS clones once"))
                Text(String(localized: "Copies made by Finder, Xcode and simulators share data until changed. Without this option every copy counts in full. Scanning is a little slower. Applies to the next scan."))
            }
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


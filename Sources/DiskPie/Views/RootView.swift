import QuickLook
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.root != nil {
                MainView()
            } else if model.isScanning {
                ScanningPlaceholder()
            } else {
                StartView()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in model.handleDrop(urls) }
        .sheet(isPresented: $model.showOnboarding) { AccessOnboardingView() }
        .quickLookPreview($model.quickLookURL)
        .onAppear { model.onLaunch() }
    }
}

struct ScanningPlaceholder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Читаю \(model.rootPath)…").foregroundStyle(.secondary)
            Button("Отмена") { model.closeScan() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

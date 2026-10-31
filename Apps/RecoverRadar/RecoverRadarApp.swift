import AppKit
import SwiftUI
import RecoveryUI

@main
struct RecoverRadarApp: App {
    @StateObject private var model = DashboardModel()

    var body: some Scene {
        WindowGroup(id: "dashboard") {
            ContentView(model: model)
        }
        .defaultSize(width: 740, height: 900)

        Window("桌面小组件预览", id: "widget-preview") {
            WidgetPreviewGallery()
        }
        .defaultSize(width: 920, height: 700)
        .windowResizability(.contentSize)

        MenuBarExtra("Recovery Radar", systemImage: "waveform.path.ecg", isInserted: Binding(
            get: { model.showMenuBar }, set: model.setShowMenuBar
        )) {
            MenuContent(model: model)
        }
    }
}

private struct MenuContent: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.status)
        Button("打开恢复雷达") {
            openWindow(id: "dashboard")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        Button("立即同步", action: model.startSync)
            .disabled(!model.isConnected || model.requiresAuthorization || model.isBusy)
        Divider()
        Button("退出") { NSApplication.shared.terminate(nil) }
    }
}

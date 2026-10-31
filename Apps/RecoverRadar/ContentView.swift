import SwiftUI
import COROSIntegration
import RecoveryCore
import RecoveryUI

struct ContentView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                connectionSettings
                if let snapshot = model.snapshot {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(alignment: .leading, spacing: 10) {
                            RecoveryDashboardView(snapshot: snapshot, now: context.date)
                                .padding(22)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                            let zone = TimeZone(identifier: snapshot.timeZoneIdentifier) ?? .current
                            Text("数据日期：\(snapshot.day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: zone))) · \(snapshot.timeZoneIdentifier)")
                                .font(.caption).foregroundStyle(.secondary)
                            if snapshot.isStale(at: context.date) {
                                Label("部分数据需要更新，请查看各项状态。", systemImage: "clock.badge.exclamationmark")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("等待恢复数据", systemImage: "waveform.path.ecg",
                                           description: Text("连接 COROS 后读取当天与近30天记录。也可以先预览合成数据。"))
                        .frame(minHeight: 180)
                }
                actions
                preferences
                VStack(alignment: .leading, spacing: 6) {
                    Text("如何阅读").font(.headline)
                    Text("虚线是过去30个完整日的个人中位数，与当天值共用固定刻度，位置随基线数值变化。睡眠、HRV、运动负荷越高越向外；静息心率、压力越低越向外。负荷向外不代表更好，图形面积不是综合恢复分。")
                    Text("绘图范围：睡眠0–100分、HRV 0–150 ms、静息心率40–100 bpm、压力0–100分、负荷0–2倍；超出范围截到边缘，原值保留。这些范围不是健康标准。压力管理的原始值为日平均压力。少于7个历史有效日的轴留空；未完整日标为暂定。每项显示自己的读取时间与基线覆盖度。")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .frame(minWidth: 650, minHeight: 650)
        .task { await model.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.syncIfDue() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            model.syncIfDue(interval: 0)
        }
        .onOpenURL { url in
            if url.host == "dashboard" { model.syncIfDue() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recovery Radar").font(.largeTitle.bold())
            Text("睡眠与恢复 · macOS 原生小组件").foregroundStyle(.secondary)
            Button("查看桌面小组件效果", systemImage: "rectangle.3.group") {
                openWindow(id: "widget-preview")
            }
            .padding(.top, 6)
            if model.isPreviewBuild {
                Label("本地开发预览 · 此构建不安装桌面小组件", systemImage: "hammer")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var connectionSettings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(model.requiresAuthorization ? "需要重新授权" : (model.isConnected ? "已连接 COROS" : "连接 COROS"),
                      systemImage: model.isConnected ? "checkmark.circle" : "link")
                    .font(.headline)
                if !model.isConnected || model.requiresAuthorization {
                    Text("已根据本机时区自动配置 · \(model.timeZoneIdentifier)")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(model.requiresAuthorization ? "重新授权" : "连接 COROS", action: model.startConnect)
                        .buttonStyle(.borderedProminent).disabled(!model.canConnect)
                    Text("点击连接后，在默认浏览器中登录 COROS。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("跟随本机时区 · \(model.timeZoneIdentifier)")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("如需切换账号，请先断开并清除本地数据。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.isBusy)
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout)
            }
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            HStack {
                if model.isBusy {
                    Button("取消", action: model.cancel)
                } else if model.isConnected {
                    Button("立即同步", action: model.startSync)
                        .buttonStyle(.borderedProminent).disabled(model.requiresAuthorization)
                    Button("断开并清除数据", action: model.startDisconnect)
                } else {
                    Button("预览演示", action: model.previewDemo)
                    Button(model.isPreviewBuild ? "保存演示" : "将演示显示到小组件", action: model.saveDemo)
                    Button("清除本地数据", action: model.startDisconnect)
                }
            }
            Text(model.isPreviewBuild
                 ? "此预览可测试连接与同步；桌面小组件需要完整 Xcode、签名和 App Group。"
                 : "运行期间每小时同步；回到应用时按需更新。小组件的实际刷新时机由系统决定。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("在菜单栏显示，方便保持应用运行", isOn: Binding(
                get: { model.showMenuBar }, set: { model.setShowMenuBar($0) }
            ))
            Toggle("登录 Mac 时启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .disabled(model.isPreviewBuild)
        }
        .font(.callout)
    }
}

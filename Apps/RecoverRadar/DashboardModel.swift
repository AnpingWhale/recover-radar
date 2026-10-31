import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI
import WidgetKit
import COROSIntegration
import RecoveryCore

@MainActor
final class DashboardModel: ObservableObject {
    @Published var snapshot: RadarSnapshot?
    @Published var status = "尚未连接 COROS"
    @Published var errorMessage: String?
    @Published var isBusy = false
    @Published var isConnected = false
    @Published var requiresAuthorization = false
    @Published private(set) var regionCode = UserDefaults.standard.string(forKey: "coros.region")
        ?? AutomaticConnectionConfiguration().region.rawValue
    @Published private(set) var timeZoneIdentifier = TimeZone.autoupdatingCurrent.identifier
    @Published private(set) var showMenuBar = UserDefaults.standard.bool(forKey: "showMenuBar")
    @Published var launchAtLogin = false

    let isPreviewBuild = Bundle.main.object(forInfoDictionaryKey: "RecoverRadarPreviewMode") as? Bool == true
    private let browser = BrowserAuthenticator()
    private var session: OAuthSession?
    private var coordinator: SyncCoordinator?
    private var coordinatorTimeZoneIdentifier: String?
    private var history: HealthHistoryStore?
    private var operation: Task<Void, Never>?
    private var automaticSync: Task<Void, Never>?
    private var hasStarted = false
    private var lastAttempt: Date?

    var canConnect: Bool {
        COROSRegion(rawValue: regionCode) != nil && TimeZone(identifier: timeZoneIdentifier) != nil
            && !isBusy && (!isConnected || requiresAuthorization)
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        if !isPreviewBuild { launchAtLogin = SMAppService.mainApp.status == .enabled }
        isBusy = true
        var shouldSynchronize = false
        // A broken App Group must not prevent credential recovery or Disconnect.
        do {
            snapshot = try snapshotStore().load()
            if let cached = snapshot, cached.timeZoneIdentifier != timeZoneIdentifier {
                snapshot = nil
                try snapshotStore().remove()
                reloadWidget()
            }
        }
        catch { errorMessage = safeMessage(error) }
        if let region = COROSRegion(rawValue: regionCode) {
            let auth = makeSession(region)
            session = auth
            do {
                let connection = try await auth.status()
                isConnected = connection.isConnected
                requiresAuthorization = connection.state == .requiresAuthorization
                if let id = connection.connectionID, connection.isConnected {
                    try configureCoordinator(auth: auth, connectionID: id)
                    if snapshot?.isDemo == true {
                        snapshot = nil
                        try snapshotStore().remove()
                        reloadWidget()
                    }
                    status = "已连接 COROS"
                    shouldSynchronize = true
                } else if requiresAuthorization {
                    status = "授权已失效，请重新连接"
                } else if snapshot?.isDemo == false {
                    // Credentials may have been removed separately. Do not display
                    // another session's production values as an active account.
                    try snapshotStore().remove()
                    snapshot = nil
                    reloadWidget()
                }
            } catch {
                status = "连接恢复未完成，请检查本地配置"
                errorMessage = safeMessage(error)
            }
        } else if snapshot?.isDemo == false {
            // Without a configured connection, an old production snapshot has no known owner.
            snapshot = nil
            do { try snapshotStore().remove(); reloadWidget() }
            catch { errorMessage = safeMessage(error) }
        }
        refreshLocalConfiguration()
        isBusy = false
        if shouldSynchronize { startSync() }
        automaticSync = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.syncIfDue(interval: 60 * 60)
            }
        }
    }

    func syncIfDue(interval: TimeInterval = 15 * 60) {
        guard !isBusy else { return }
        guard isConnected, !requiresAuthorization else { refreshLocalConfiguration(); return }
        let zoneChanged = TimeZone.autoupdatingCurrent.identifier != timeZoneIdentifier
        guard zoneChanged || (lastAttempt.map({ Date.now.timeIntervalSince($0) >= interval }) ?? true) else { return }
        startSync()
    }

    func startConnect() { begin { await self.connect() } }
    func startSync() { begin { await self.synchronize() } }
    func startDisconnect() { begin { await self.disconnect() } }

    func cancel() {
        operation?.cancel()
        browser.cancel()
        let pendingCoordinator = coordinator
        Task { await pendingCoordinator?.cancelAndWait() }
    }

    func previewDemo() {
        guard !isBusy, !isConnected else { return }
        snapshot = DemoFixtures.snapshot()
        status = "合成演示预览 · 未连接 COROS"
        errorMessage = nil
    }

    func saveDemo() {
        guard !isBusy, !isConnected else { return }
        do {
            let demo = DemoFixtures.snapshot()
            try snapshotStore().save(demo)
            snapshot = demo
            status = isPreviewBuild ? "演示已保存到本地预览" : "演示已保存，已请求小组件刷新"
            errorMessage = nil
            reloadWidget()
        } catch { errorMessage = safeMessage(error) }
    }

    func setShowMenuBar(_ visible: Bool) {
        // MenuBarExtra can echo its current visibility while updating the scene.
        // Suppress that echo before @Published emits, or it invalidates the scene again.
        guard showMenuBar != visible else { return }
        showMenuBar = visible
        UserDefaults.standard.set(visible, forKey: "showMenuBar")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        guard !isPreviewBuild else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin {
                status = "请在系统设置的登录项中允许 Recovery Radar"
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { errorMessage = "无法更改登录启动设置，请检查系统设置。" }
    }

    private func begin(_ action: @escaping @MainActor () async -> Void) {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        operation = Task {
            await action()
            isBusy = false
            operation = nil
        }
    }

    private func connect() async {
        refreshLocalConfiguration()
        let selectedTimeZone = timeZoneIdentifier
        guard let region = COROSRegion(rawValue: regionCode),
              TimeZone(identifier: selectedTimeZone) != nil else {
            errorMessage = "无法读取本机时区，请检查系统日期与时间设置。"
            return
        }
        do {
            // Verify local storage before beginning browser authorization.
            _ = try snapshotStore()
            // Drain the old writer before changing credentials, region, or time zone.
            await coordinator?.cancelAndWait()
            coordinator = nil
            let previous = session
            if let previous { _ = try await previous.disconnect() }
            let auth = previous?.region == region ? previous! : makeSession(region)
            // A selected region can contain a leftover grant from an earlier interrupted setup.
            if previous?.region != region { _ = try await auth.disconnect() }
            session = auth
            isConnected = false
            requiresAuthorization = false
            // Clear the previous account before opening the new account's authorization flow.
            let store = try historyStore()
            try await store.removeAll()
            try snapshotStore().remove()
            snapshot = nil
            reloadWidget()
            // Save the selected non-secret configuration before authorization can commit tokens.
            // Cancellation or a subsequent disk error cannot strand credentials in another region.
            UserDefaults.standard.set(region.rawValue, forKey: "coros.region")
            UserDefaults.standard.set(selectedTimeZone, forKey: "coros.timeZone")
            lastAttempt = nil
            try Task.checkCancellation()
            status = "正在打开 COROS 授权窗口…"
            let connection = try await auth.connect(using: browser)
            guard let id = connection.connectionID else { throw OAuthError.invalidStoredCredentials }
            isConnected = true
            requiresAuthorization = false
            try configureCoordinator(auth: auth, connectionID: id)
            try Task.checkCancellation()
            await synchronize()
        } catch {
            status = "连接未完成"
            errorMessage = safeMessage(error)
            // If authorization succeeded but file setup failed, preserve the
            // truthful connection state so Disconnect remains available.
            if let connection = try? await session?.status() {
                isConnected = connection.isConnected
                requiresAuthorization = connection.state == .requiresAuthorization
            }
        }
    }

    private func synchronize() async {
        guard isConnected else { return }
        status = "正在同步睡眠与恢复数据…"
        lastAttempt = .now
        do {
            refreshLocalConfiguration()
            if coordinatorTimeZoneIdentifier != timeZoneIdentifier {
                await coordinator?.cancelAndWait()
                coordinator = nil
                snapshot = nil
                try snapshotStore().remove()
                reloadWidget()
            }
            if coordinator == nil, let auth = session,
               let id = try await auth.status().connectionID {
                try configureCoordinator(auth: auth, connectionID: id)
            }
            guard let coordinator else { throw OAuthError.notConnected }
            let result = try await coordinator.synchronize()
            try Task.checkCancellation()
            snapshot = result
            requiresAuthorization = result.connectionState == .reauthorizationRequired
            status = switch result.syncState {
            case .succeeded: "五项指标已更新"
            case .partial: "部分指标已更新，请查看各项状态"
            case .failed: "同步未成功，保留已有数据"
            default: "同步完成"
            }
            reloadWidget()
        } catch {
            status = "同步未完成"
            errorMessage = safeMessage(error)
        }
    }

    private func disconnect() async {
        status = "正在移除连接与本地数据…"
        await coordinator?.cancelAndWait()
        coordinator = nil
        // Local data removal is attempted independently of remote revocation.
        var localFailure: (any Error)?
        do { try await historyStore().removeAll() } catch { localFailure = error }
        do { try snapshotStore().remove() } catch { localFailure = error }
        snapshot = nil
        reloadWidget()
        // Clear this app's credential slots in every region, including grants whose
        // setup was interrupted before a selected region was saved to preferences.
        let currentSession = session
        var credentialFailure: (any Error)?
        var failedSession: OAuthSession?
        var revocationUnconfirmed = false
        for region in COROSRegion.allCases {
            let auth = currentSession?.region == region ? currentSession! : makeSession(region)
            do {
                let result = try await auth.disconnect()
                revocationUnconfirmed = revocationUnconfirmed || (result.hadCredentials && !result.revocationConfirmed)
            } catch {
                credentialFailure = error
                failedSession = auth
            }
        }
        if let credentialFailure {
            session = failedSession
            if let connection = try? await failedSession?.status() {
                isConnected = connection.isConnected
                requiresAuthorization = connection.state == .requiresAuthorization
            }
            errorMessage = safeMessage(credentialFailure)
            status = "本地数据已清理，凭证移除失败，请重试"
        } else {
            isConnected = false
            requiresAuthorization = false
            session = nil
            refreshLocalConfiguration()
            lastAttempt = nil
            status = revocationUnconfirmed
                ? "本地连接与数据已移除；远端撤销尚未确认" : "已断开，已移除本地数据"
        }
        if let localFailure {
            status = "本地数据清理未完全成功，请重试"
            errorMessage = safeMessage(localFailure)
        }
    }

    private func makeSession(_ region: COROSRegion) -> OAuthSession {
        OAuthSession(region: region, credentialStore: KeychainOAuthCredentialStore(
            service: (Bundle.main.bundleIdentifier ?? "org.example.RecoverRadar") + ".oauth",
            useDataProtectionKeychain: !isPreviewBuild
        ))
    }

    private func refreshLocalConfiguration() {
        let configuration = AutomaticConnectionConfiguration(
            authenticatedRegion: (isConnected || requiresAuthorization) ? session?.region : nil
        )
        if regionCode != configuration.region.rawValue { regionCode = configuration.region.rawValue }
        if timeZoneIdentifier != configuration.timeZoneIdentifier { timeZoneIdentifier = configuration.timeZoneIdentifier }
    }

    private func configureCoordinator(auth: OAuthSession, connectionID: UUID) throws {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw HealthHistoryStoreError.invalidScope }
        let source = COROSHealthDataSource(client: COROSMCPClient(endpoint: auth.region.mcpURL, tokenProvider: auth))
        coordinator = SyncCoordinator(source: source, history: try historyStore(), snapshots: try snapshotStore(),
                                      scope: HistoryScope(connectionID: connectionID, region: auth.region.rawValue,
                                                          timeZoneIdentifier: timeZoneIdentifier))
        coordinatorTimeZoneIdentifier = timeZoneIdentifier
    }

    private func privateDirectory() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "RecoverRadar", isDirectory: true)
    }

    private func historyStore() throws -> HealthHistoryStore {
        if let history { return history }
        let store = HealthHistoryStore(directory: try privateDirectory().appendingPathComponent("History", isDirectory: true))
        history = store
        return store
    }

    private func snapshotStore() throws -> SnapshotStore {
        if isPreviewBuild {
            return SnapshotStore(directory: try privateDirectory().appendingPathComponent("PreviewSnapshots", isDirectory: true))
        }
        guard let identifier = Bundle.main.object(forInfoDictionaryKey: "RecoverRadarAppGroupIdentifier") as? String,
              !identifier.isEmpty, !identifier.contains("$(") else { throw SnapshotStoreError.unavailableAppGroup }
        return SnapshotStore(directory: try SharedContainer.directory(appGroupIdentifier: identifier))
    }

    private func reloadWidget() {
        if !isPreviewBuild { WidgetCenter.shared.reloadTimelines(ofKind: WidgetConstants.kind) }
    }

    private func safeMessage(_ error: any Error) -> String {
        if error is CancellationError || (error as? OAuthError) == .cancelled { return "操作已取消。" }
        if let error = error as? OAuthError { return error.localizedDescription }
        if let error = error as? SnapshotStoreError { return error.localizedDescription }
        if let error = error as? HealthHistoryStoreError { return error.localizedDescription }
        return "操作未完成，请检查网络或本地配置后重试。"
    }
}

import apfelkern
import AppKit
import Foundation
import Observation
import UserNotifications

@MainActor @Observable
final class PushNotifications {
    static let shared = PushNotifications()
    private(set) var remoteDelivery = false
    private(set) var status = "Local notifications"
    private(set) var serverId: String?
    var enabled: Bool {
        didSet {
            revision += 1
            defaults.set(enabled, forKey: "push-enabled")
            if !enabled {
                queueRemoval(client)
                remoteDelivery = false
                clearRemoteBinding()
            }
            synchronize()
        }
    }
    private let defaults: UserDefaults
    let installationId: String
    private var client: APIClient?
    private weak var model: AppModel?
    private var apnsToken: String?
    private var pendingRemovals: [PendingPushRemoval] = []
    private var revision = 0
    private var syncTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var needsSync = false
    private var ledger: PushEventLedger
    private var pendingTap: ActivityEvent?
    private var observations: [NSObjectProtocol] = []
    private var authorized = false
    private let saveRemovals: ([PendingPushRemoval]) throws -> Void
    private let environment: String?
    private let bundleId: String?
    private let permission: () async -> Bool
    private let makeClient: (String, String) -> APIClient
    private var pendingLocalTap: (agentId: String, serverURL: String)?
    var openMainWindow: (() -> Void)? { didSet { routePendingTap() } }

    init(
        defaults: UserDefaults = .standard,
        environment: String? = Bundle.main.object(forInfoDictionaryKey: "CrumblePushEnvironment") as? String,
        bundleId: String? = Bundle.main.bundleIdentifier,
        loadRemovals: @escaping () -> [PendingPushRemoval] = {
            guard let text = Keychain.read("push-pending-removals"), let data = text.data(using: .utf8) else {
                return []
            }
            return (try? JSONDecoder().decode([PendingPushRemoval].self, from: data)) ?? []
        },
        saveRemovals: @escaping ([PendingPushRemoval]) throws -> Void = { removals in
            let data = try JSONEncoder().encode(removals)
            guard let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeRawData) }
            try Keychain.write("push-pending-removals", value: text)
        },
        makeClient: @escaping (String, String) -> APIClient = { APIClient(baseURL: $0, token: $1) },
        permission: @escaping () async -> Bool = {
            let center = UNUserNotificationCenter.current()
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            }
            return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }
    ) {
        self.defaults = defaults
        self.environment = ["development", "production"].contains(environment ?? "") ? environment : nil
        self.bundleId = bundleId
        self.makeClient = makeClient
        self.saveRemovals = saveRemovals
        self.permission = permission
        enabled = defaults.object(forKey: "push-enabled") as? Bool ?? true
        installationId = defaults.string(forKey: "push-installation-id") ?? UUID().uuidString
        defaults.set(installationId, forKey: "push-installation-id")
        ledger = PushEventLedger(keys: defaults.stringArray(forKey: "push-seen-events") ?? [])
        pendingRemovals = loadRemovals()
    }

    func start(model: AppModel) {
        self.model = model
        model.onNotificationContextChange = { [weak self] in self?.synchronize() }
        model.onNotificationConnectionChange = { [weak self] in self?.connect($0) }
        connect(model.client)
        routePendingTap()
        guard heartbeat == nil, Bundle.main.bundleIdentifier != nil else { return }
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification
        ] {
            observations.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    Task { @MainActor in self.synchronize() }
                })
        }
        heartbeat = Task {
            while !Task.isCancelled {
                await refreshAuthorization()
                synchronize()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func connect(_ candidate: APIClient?) {
        if let old = client, old.baseURL != candidate?.baseURL || old.token != candidate?.token {
            queueRemoval(old)
            serverId = nil
            pendingTap = nil
            pendingLocalTap = nil
        }
        let changed = client?.baseURL != candidate?.baseURL || client?.token != candidate?.token
        client = candidate
        if changed {
            remoteDelivery = candidate?.baseURL == defaults.string(forKey: "push-remote-server-url")
            serverId = remoteDelivery ? defaults.string(forKey: "push-remote-server-id") : nil
            revision += 1
        }
        synchronize()
    }

    func receivedToken(_ data: Data) {
        let value = data.map { String(format: "%02x", $0) }.joined()
        guard value != apnsToken else { return }
        apnsToken = value
        revision += 1
        synchronize()
    }

    func prepareForTermination() async {
        guard let client, remoteDelivery else { return }
        try? await client.pushPresence(installationId, active: false, agentId: nil, timeout: 2)
    }

    func registrationFailed() { status = "Push registration failed; retrying automatically" }

    private func refreshAuthorization() async {
        authorized = await permission()
        if !authorized || !enabled {
            revision += 1
            queueRemoval(client)
            remoteDelivery = false
            status = enabled ? "Notifications disabled in System Settings" : "Notifications disabled"
        } else if environment != nil {
            NSApp.registerForRemoteNotifications()
        }
    }

    private func queueRemoval(_ client: APIClient?) {
        guard let client else { return }
        let item = PendingPushRemoval(baseURL: client.baseURL, token: client.token)
        if !pendingRemovals.contains(item) { pendingRemovals.append(item) }
        persistRemovals()
    }

    private func persistRemovals() {
        do { try saveRemovals(pendingRemovals) } catch { status = "Could not save pending push removal" }
    }

    func synchronize() {
        guard client != nil || !pendingRemovals.isEmpty else { return }
        needsSync = true
        guard syncTask == nil else { return }
        syncTask = Task {
            repeat {
                needsSync = false
                await syncOnce()
            } while needsSync
            syncTask = nil
        }
    }
}

extension PushNotifications {
    private func syncOnce() async {
        await removePendingRegistrations()
        guard enabled, let client else { return }
        let version = revision
        do {
            let identity = try await client.pushStatus()
            guard version == revision else { return }
            guard !identity.serverId.isEmpty else { throw URLError(.badServerResponse) }
            serverId = identity.serverId
            routePendingTap()
            if identity.transports["apns"] != true {
                remoteDelivery = false
                clearRemoteBinding()
            }
            guard let device = registrationDevice(client: client) else { return }
            guard await authorizeRegistration(client: client, version: version) else { return }
            try await register(client: client, identity: identity, device: device, version: version)
        } catch let error as APIError where error.statusCode == 404 {
            guard version == revision else { return }
            remoteDelivery = false
            clearRemoteBinding()
            routePendingTap()
            status = "Local notifications · Server push unavailable"
        } catch {
            guard version == revision else { return }
            // Keep an acknowledged remote registration authoritative during a transient outage.
            status = "Push connection interrupted; retrying automatically"
        }
    }

    private func removePendingRegistrations() async {
        for item in pendingRemovals {
            do {
                try await makeClient(item.baseURL, item.token).unregisterPush(installationId)
                pendingRemovals.removeAll { $0 == item }
                persistRemovals()
            } catch let error as APIError where error.statusCode == 404 {
                pendingRemovals.removeAll { $0 == item }
                persistRemovals()
            } catch { /* Retain credentials in Keychain and retry after reconnection. */  }
        }
    }

    private func registrationDevice(client: APIClient) -> PushDevice? {
        guard let environment, let bundle = bundleId else {
            if remoteDelivery { queueRemoval(client) }
            remoteDelivery = false
            clearRemoteBinding()
            status = "Local notifications · APNs signing not configured"
            return nil
        }
        guard let apnsToken else {
            status = "Waiting for APNs device registration"
            return nil
        }
        return PushDevice(
            platform: "macos", transport: "apns", token: apnsToken,
            environment: environment, bundleId: bundle)
    }

    private func authorizeRegistration(client: APIClient, version: Int) async -> Bool {
        authorized = await permission()
        guard version == revision else { return false }
        guard authorized else {
            queueRemoval(client)
            remoteDelivery = false
            status = "Notifications disabled in System Settings"
            return false
        }
        return true
    }

    private func register(
        client: APIClient, identity: PushStatus, device: PushDevice, version: Int
    ) async throws {
        let result = try await client.registerPush(installationId, device: device)
        guard version == revision else {
            queueRemoval(client)
            needsSync = true
            return
        }
        guard result.serverId == identity.serverId else { throw URLError(.badServerResponse) }
        serverId = result.serverId
        remoteDelivery = result.remoteDelivery
        if result.remoteDelivery {
            defaults.set(client.baseURL, forKey: "push-remote-server-url")
            defaults.set(result.serverId, forKey: "push-remote-server-id")
        } else {
            clearRemoteBinding()
        }
        status =
            result.remoteDelivery
            ? "Remote notifications connected" : "Local notifications · Server push not configured"
        let agentId: String? = if case .agent(let id) = model?.route { id } else { nil }
        let active =
            NSApp?.isActive == true
            && NSApp.windows.contains { $0.identifier?.rawValue == "main" && $0.isVisible && !$0.isMiniaturized }
        // A key content window is a fallback for SwiftUI's generated window identifier.
        let chatVisible =
            active
            || (NSApp?.isActive == true && NSApp.keyWindow?.isVisible == true
                && NSApp.keyWindow?.title == "Crumble")
        try await client.pushPresence(installationId, active: chatVisible, agentId: chatVisible ? agentId : nil)
    }

    private func clearRemoteBinding() {
        defaults.removeObject(forKey: "push-remote-server-url")
        defaults.removeObject(forKey: "push-remote-server-id")
    }

    /// Waits for the serialized registration work, used by lifecycle shutdown and tests.
    func waitForSynchronization() async { await syncTask?.value }

    func shouldPostLocal(_ event: ActivityEvent) -> Bool {
        guard enabled, !remoteDelivery else { return false }
        guard let id = event.eventId, let server = event.serverId, !server.isEmpty else { return true }
        guard serverId == nil || serverId == server else { return false }
        return remember(server: server, event: id)
    }

    func presentation(for event: ActivityEvent) -> UNNotificationPresentationOptions {
        guard enabled, let server = event.serverId, server == serverId, let id = event.eventId,
            remember(server: server, event: id),
            notification(for: event, in: NotificationContext(appActive: NSApp?.isActive ?? false, route: model?.route))
                != nil
        else { return [] }
        return [.banner, .sound]
    }

    private func remember(server: String, event: String) -> Bool {
        let inserted = ledger.insert(server: server, event: event)
        if inserted { defaults.set(ledger.keys, forKey: "push-seen-events") }
        return inserted
    }

    func openLocal(agentId: String, serverURL: String) {
        pendingLocalTap = (agentId, serverURL)
        routePendingTap()
    }

    func open(_ event: ActivityEvent) {
        guard event.type == "reply", event.origin != "bot", event.serverId != nil, event.eventId != nil else { return }
        pendingTap = event
        routePendingTap()
        synchronize()
    }

    private func routePendingTap() {
        guard let model else { return }
        if let local = pendingLocalTap, let client {
            pendingLocalTap = nil
            if local.serverURL == client.baseURL { showChat(local.agentId, model: model) }
        }
        guard let event = pendingTap, let server = serverId else { return }
        pendingTap = nil
        guard event.serverId == server else { return }
        showChat(event.agentId, model: model)
    }

    private func showChat(_ id: String, model: AppModel) {
        NSApp?.activate()
        openMainWindow?()
        model.openNotificationChat(id)
    }
}

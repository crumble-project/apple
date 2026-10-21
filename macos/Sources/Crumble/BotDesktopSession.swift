import apfelkern
import Foundation

/// One bot desktop window's connection: the viewer link, who holds control, and a take or hand-back
/// request that waits for the server.
@MainActor @Observable
final class BotDesktopSession {
    enum Action: Equatable {
        case take, handBack, waiting
    }

    let agentID: String
    private let client: APIClient

    var link: URL?
    var holder: DesktopControl.Holder = .bot
    var changes = 0
    /// The holder asked for and not yet confirmed; control shows the previous holder until then.
    var pending: DesktopControl.Holder?
    var error = ""

    private var events: Task<Void, Never>?

    init(agentID: String, client: APIClient) {
        self.agentID = agentID
        self.client = client
    }

    nonisolated static func action(for holder: DesktopControl.Holder, pending: DesktopControl.Holder?) -> Action {
        if pending != nil { return .waiting }
        return holder == .owner ? .handBack : .take
    }

    var action: Action { Self.action(for: holder, pending: pending) }

    func connect() {
        reconnect()
        guard events == nil else { return }
        let client = client
        let agentID = agentID
        events = Task { [weak self] in
            var backoff = Duration.milliseconds(500)
            while !Task.isCancelled {
                do {
                    try await client.desktopEvents(agentID) { [weak self] state in
                        await self?.apply(state)
                    }
                } catch {
                    if let error = error as? APIError, error.statusCode == 404 { return }
                }
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(8))
            }
        }
    }

    /// Viewer links work once, so every (re)load of the viewer needs a new one.
    func reconnect() {
        Task {
            do {
                link = try await client.desktopViewer(agentID).url
                error = ""
            } catch {
                self.error = friendlyError(error)
            }
        }
    }

    func take() { request(.owner) }

    func handBack() { request(.bot) }

    func close() {
        events?.cancel()
        events = nil
    }

    private func request(_ wanted: DesktopControl.Holder) {
        guard pending == nil else { return }
        pending = wanted
        error = ""
        Task {
            do {
                apply(try await client.setDesktopControl(agentID, holder: wanted))
            } catch {
                self.error = friendlyError(error)
            }
            pending = nil
        }
    }

    private func apply(_ state: DesktopControl) {
        // Events and request answers can arrive out of order; the change count orders them.
        guard state.changes >= changes else { return }
        holder = state.holder
        changes = state.changes
    }
}

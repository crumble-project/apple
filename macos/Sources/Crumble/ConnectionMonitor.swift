import AppKit
import Foundation
import Network

/// The parts of a network path that decide whether open streams may have died.
struct NetworkPathState: Equatable {
    var satisfied: Bool
    var interfaces: [String]

    /// A path that comes back, or moves to other interfaces, can leave a stream on a dead socket.
    /// The first report is the starting state, not a change.
    static func shouldReconnect(from old: NetworkPathState?, to new: NetworkPathState) -> Bool {
        guard let old, new.satisfied else { return false }
        return !old.satisfied || old.interfaces != new.interfaces
    }
}

/// Restarts server streams after wake and network changes, where waiting for the streams' idle
/// timeout would delay notifications by up to a minute.
@MainActor
final class ConnectionMonitor {
    private let monitor = NWPathMonitor()
    private var path: NetworkPathState?
    private var observer: NSObjectProtocol?

    func start(onChange: @escaping @MainActor () -> Void) {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { onChange() }
        }
        monitor.pathUpdateHandler = { [weak self] update in
            let state = NetworkPathState(
                satisfied: update.status == .satisfied, interfaces: update.availableInterfaces.map(\.name))
            MainActor.assumeIsolated {
                guard let self else { return }
                let old = self.path
                self.path = state
                if NetworkPathState.shouldReconnect(from: old, to: state) { onChange() }
            }
        }
        monitor.start(queue: .main)
    }
}

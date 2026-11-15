import apfelkern
import SwiftUI

/// Pins or unpins a sidebar row from its context menu.
struct PinButton: View {
    @Environment(AppModel.self) private var model
    let route: Route

    var body: some View {
        if model.isPinned(route) {
            Button("Unpin", systemImage: "pin.slash") { model.setPinned(route, false) }
                .disabled(!model.canChangePins)
        } else {
            Button("Pin", systemImage: "pin") { model.setPinned(route, true) }
                .disabled(!model.canPin(route))
        }
    }
}

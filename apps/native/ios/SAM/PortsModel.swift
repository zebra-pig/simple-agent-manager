import Foundation
import Observation

@MainActor @Observable final class PortsModel {
    let core: PortsViewModel
    private(set) var state: PortsState
    var confirmPublic = false

    /// The switch reads confirmed state. Only user writes request a change;
    /// observer updates never trigger another visibility request.
    var publicAccess: Bool {
        get { state.publicEnabled }
        set {
            guard newValue != state.publicEnabled else { return }
            if newValue { confirmPublic = true }
            else { Task { await core.setPublic(enabled: false) } }
        }
    }

    init(app: App) {
        core = PortsViewModel(app: app)
        state = core.state()
        core.setObserver(observer: Relay { [weak self] in self?.state = $0 })
    }
}

extension Relay: PortsObserver where State == PortsState {
    func onStateChanged(state: PortsState) { send(state) }
}

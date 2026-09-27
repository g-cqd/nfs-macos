import Observation

@MainActor @Observable
package final class RosettaSetup {
  package private(set) var state = RosettaState.unchecked
  private let service: any RosettaProviding

  package init(service: any RosettaProviding = NativeRosetta()) { self.service = service }

  package var isAvailable: Bool { state == .available }
  package var isBusy: Bool { state == .checking || state == .installing }
  package var issue: String? {
    if case .failed(let message) = state { return message }
    return nil
  }

  package func refresh() async {
    guard !isBusy else { return }
    let previous = state
    state = .checking
    do {
      let available = try await service.isAvailable()
      try Task.checkCancellation()
      state = available ? .available : .missing
    } catch {
      state = Task.isCancelled ? previous : .failed(error.localizedDescription)
    }
  }

  package func install() async {
    guard !isBusy, !isAvailable else { return }
    let previous = state
    state = .installing
    do {
      try await service.requestInstallation()
      try Task.checkCancellation()
      let available = try await service.isAvailable()
      try Task.checkCancellation()
      state = available ? .available : .missing
    } catch {
      state = Task.isCancelled ? previous : .failed(error.localizedDescription)
    }
  }
}

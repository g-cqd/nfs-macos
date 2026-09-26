enum LauncherPhase: Equatable {
  case ready
  case preparing
  case playing
  case finished
  case failed(String)

  var title: String {
    switch self {
    case .ready: "Ready to play"
    case .preparing: "Applying your configuration"
    case .playing: "Your game is running"
    case .finished: "Ready for another race"
    case .failed: "The operation could not finish"
    }
  }

  var detail: String {
    switch self {
    case .preparing:
      "The first launch creates your own game folder. This can take a minute."
    case .ready: "Choose your settings, then press Play."
    case .playing: "Quit from the game when you finish. Your progress stays in your player folder."
    case .finished: "Play applies the selected graphics and controller settings before starting."
    case .failed(let message): message
    }
  }

  var isBusy: Bool { self == .preparing || self == .playing }
}

enum LauncherPhase: Equatable {
  case ready
  case needsGameData
  case needsRosetta
  case installingRosetta
  case preparing
  case playing
  case finished
  case failed(String)

  var title: String {
    switch self {
    case .ready: "Ready to play"
    case .needsGameData: "Import your game"
    case .needsRosetta: "Rosetta is required"
    case .installingRosetta: "Installing Rosetta"
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
    case .needsRosetta:
      "Choose Install Rosetta on the Play screen. After installation, return here or choose Refresh."
    case .installingRosetta:
      "Complete Apple's installation request. The starter will check again when it finishes."
    case .needsGameData:
      "Choose Import game data on the Play screen and select your installed Most Wanted (2005) PC folder."
    case .playing: "Quit from the game when you finish. Your progress stays in your player folder."
    case .finished: "Play applies the selected graphics and controller settings before starting."
    case .failed(let message): message
    }
  }

  var isBusy: Bool { self == .preparing || self == .playing || self == .installingRosetta }
}

enum FarCry2Phase: Equatable {
  case preparing, ready, playing, needsRosetta, needsGameData
  case failed(String)
  var isBusy: Bool { self == .preparing || self == .playing }
  var message: String {
    switch self {
    case .preparing: "Preparing Far Cry 2…"
    case .ready: "Ready to play"
    case .playing: "Far Cry 2 is running. Close the game to return here."
    case .needsRosetta: "Rosetta is required to run this Intel game."
    case .needsGameData: "Import your installed Far Cry 2 folder to begin."
    case .failed(let message): message
    }
  }
}

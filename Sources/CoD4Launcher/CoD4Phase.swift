enum CoD4Phase: Equatable {
  case preparing, ready, playing, needsRosetta, needsGameData
  case failed(String)
  var isBusy: Bool { self == .preparing || self == .playing }
  var message: String {
    switch self {
    case .preparing: "Preparing Call of Duty 4…"
    case .ready: "Ready to play"
    case .playing: "Call of Duty 4 is running. Close the game to return here."
    case .needsRosetta: "Rosetta is required to run this Intel game."
    case .needsGameData: "Import your Call of Duty 4 Windows game folder to begin."
    case .failed(let message): message
    }
  }
}

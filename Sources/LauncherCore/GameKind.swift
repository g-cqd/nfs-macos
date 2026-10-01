/// Identifies the installation contract; manifests cannot cross game boundaries.
package enum GameKind: String, Codable, Sendable {
  case nfsmw, cod4, nfs2015

  package var executable: String {
    switch self {
    case .nfsmw: "speed.exe"
    case .cod4: "iw3sp.exe"
    case .nfs2015: "NFS16.exe"
    }
  }

  package var folder: String {
    switch self {
    case .nfsmw: "NFSMW"
    case .cod4: "CoD4"
    case .nfs2015: "NFS2015"
    }
  }

  package var helper: String {
    switch self {
    case .nfsmw: "NFSMWSession"
    case .cod4: "CoD4Session"
    case .nfs2015: "NFS2015Session"
    }
  }

  /// The player-visible name used in shared launch and session messages.
  package var title: String {
    switch self {
    case .nfsmw: "Most Wanted"
    case .cod4: "Call of Duty 4"
    case .nfs2015: "Need for Speed"
    }
  }

  /// Indicates that the app publishes verified copies of the original assets it was given.
  ///
  /// Need for Speed (2015) is the exception: its store client activates the executable in
  /// place, so the app references the player's own installation instead of copying it.
  package var copiesGameData: Bool { self != .nfs2015 }

  /// Indicates that the game is started by a store client the player installs and signs into.
  package var requiresStoreClient: Bool { self == .nfs2015 }

  var byteLimit: Int {
    switch self {
    case .nfsmw: 6_000_000_000
    case .cod4: 20_000_000_000
    case .nfs2015: 0
    }
  }

  var preservedConfiguration: [String] {
    switch self {
    case .nfsmw:
      [
        "mtld3d.conf", "scripts/NFS_XtendedInput.ini", "scripts/NFSMostWanted.WidescreenFix.ini",
        "scripts/XtendedInputMaps",
      ]
    case .cod4: ["mtld3d.conf"]
    // Nothing in a referenced installation belongs to this app, so nothing is carried forward.
    case .nfs2015: []
    }
  }

  func isOriginalData(_ path: String) -> Bool {
    switch self {
    case .nfsmw: GameDataFiles.contains(path)
    case .cod4: path != "mtld3d.conf"
    case .nfs2015: true
    }
  }
}

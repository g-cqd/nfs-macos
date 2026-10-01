/// Identifies the installation contract; manifests cannot cross game boundaries.
package enum GameKind: String, Codable, Sendable {
  case nfsmw, cod4, farcry2, nfs2015

  /// The executable, relative to the game folder, whose presence marks a usable installation.
  package var executable: String {
    switch self {
    case .nfsmw: "speed.exe"
    case .cod4: "iw3sp.exe"
    case .farcry2: "bin/FarCry2.exe"
    case .nfs2015: "NFS16.exe"
    }
  }

  package var folder: String {
    switch self {
    case .nfsmw: "NFSMW"
    case .cod4: "CoD4"
    case .farcry2: "FarCry2"
    case .nfs2015: "NFS2015"
    }
  }

  package var helper: String {
    switch self {
    case .nfsmw: "NFSMWSession"
    case .cod4: "CoD4Session"
    case .farcry2: "FarCry2Session"
    case .nfs2015: "NFS2015Session"
    }
  }

  /// The player-visible name used in shared launch and session messages.
  package var title: String {
    switch self {
    case .nfsmw: "Most Wanted"
    case .cod4: "Call of Duty 4"
    case .farcry2: "Far Cry 2"
    case .nfs2015: "Need for Speed"
    }
  }

  /// The renderer configuration lives next to the executable, which is `bin` for Far Cry 2.
  package var rendererConfiguration: String {
    self == .farcry2 ? "bin/mtld3d.conf" : "mtld3d.conf"
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
    case .farcry2: 16_000_000_000
    case .nfs2015: 0
    }
  }

  /// Far Cry 2 shipped on FAT32-era media, so one archive stays below 4 GB.
  var fileByteLimit: Int { self == .farcry2 ? 4_000_000_000 : 2_000_000_000 }

  var preservedConfiguration: [String] {
    switch self {
    case .nfsmw:
      [
        "mtld3d.conf", "scripts/NFS_XtendedInput.ini", "scripts/NFSMostWanted.WidescreenFix.ini",
        "scripts/XtendedInputMaps",
      ]
    case .cod4: ["mtld3d.conf"]
    case .farcry2: [rendererConfiguration]
    // Nothing in a referenced installation belongs to this app, so nothing is carried forward.
    case .nfs2015: []
    }
  }

  func isOriginalData(_ path: String) -> Bool {
    switch self {
    case .nfsmw: GameDataFiles.contains(path)
    case .cod4: path != "mtld3d.conf"
    case .farcry2: path != rendererConfiguration
    case .nfs2015: true
    }
  }
}

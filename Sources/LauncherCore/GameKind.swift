/// Identifies the installation contract; manifests cannot cross game boundaries.
package enum GameKind: String, Codable, Sendable {
  case nfsmw, cod4, farcry2

  /// The executable, relative to the game folder, whose presence marks a usable installation.
  package var executable: String {
    switch self {
    case .nfsmw: "speed.exe"
    case .cod4: "iw3sp.exe"
    case .farcry2: "bin/FarCry2.exe"
    }
  }
  package var folder: String {
    switch self {
    case .nfsmw: "NFSMW"
    case .cod4: "CoD4"
    case .farcry2: "FarCry2"
    }
  }
  package var helper: String {
    switch self {
    case .nfsmw: "NFSMWSession"
    case .cod4: "CoD4Session"
    case .farcry2: "FarCry2Session"
    }
  }
  /// Games whose working directory Wine cannot reverse-map through the `C:` link need a game-only drive.
  package var usesGameDrive: Bool { self != .nfsmw }
  /// The renderer configuration lives next to the executable, which is `bin` for Far Cry 2.
  package var rendererConfiguration: String {
    self == .farcry2 ? "bin/mtld3d.conf" : "mtld3d.conf"
  }
  var byteLimit: Int {
    switch self {
    case .nfsmw: 6_000_000_000
    case .cod4: 20_000_000_000
    case .farcry2: 16_000_000_000
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
    }
  }

  func isOriginalData(_ path: String) -> Bool {
    switch self {
    case .nfsmw: GameDataFiles.contains(path)
    case .cod4: path != "mtld3d.conf"
    case .farcry2: path != rendererConfiguration
    }
  }
}

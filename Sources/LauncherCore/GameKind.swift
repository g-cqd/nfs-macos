/// Identifies the installation contract; manifests cannot cross game boundaries.
package enum GameKind: String, Codable, Sendable {
  case nfsmw, cod4

  package var executable: String { self == .nfsmw ? "speed.exe" : "iw3sp.exe" }
  package var folder: String { self == .nfsmw ? "NFSMW" : "CoD4" }
  package var helper: String { self == .nfsmw ? "NFSMWSession" : "CoD4Session" }
  var byteLimit: Int { self == .nfsmw ? 6_000_000_000 : 20_000_000_000 }
  var preservedConfiguration: [String] {
    self == .nfsmw
      ? [
        "mtld3d.conf", "scripts/NFS_XtendedInput.ini", "scripts/NFSMostWanted.WidescreenFix.ini",
        "scripts/XtendedInputMaps",
      ]
      : ["mtld3d.conf"]
  }

  func isOriginalData(_ path: String) -> Bool {
    self == .nfsmw ? GameDataFiles.contains(path) : path != "mtld3d.conf"
  }
}

import Foundation
import Testing

@testable import LauncherCore

struct FarCry2GameKindTests {
  @Test
  func `far cry 2 identifiers and executable location`() {
    #expect(GameKind.farcry2.executable == "bin/FarCry2.exe")
    #expect(GameKind.farcry2.folder == "FarCry2")
    #expect(GameKind.farcry2.helper == "FarCry2Session")
    #expect(GameKind.farcry2.rendererConfiguration == "bin/mtld3d.conf")
    #expect(GameKind(rawValue: "farcry2") == .farcry2)
  }

  @Test
  func `only the renderer configuration is app-owned`() {
    #expect(!GameKind.farcry2.isOriginalData("bin/mtld3d.conf"))
    #expect(GameKind.farcry2.isOriginalData("bin/FarCry2.exe"))
    #expect(GameKind.farcry2.isOriginalData("mtld3d.conf"), "a root file of that name is game data")
    #expect(GameKind.farcry2.preservedConfiguration == ["bin/mtld3d.conf"])
  }

  @Test(arguments: [GameKind.nfsmw, .cod4, .farcry2])
  func `existing games keep their previous contracts`(kind: GameKind) {
    switch kind {
    case .nfsmw:
      #expect(kind.executable == "speed.exe" && kind.folder == "NFSMW" && !kind.usesGameDrive)
      #expect(kind.rendererConfiguration == "mtld3d.conf")
    case .cod4:
      #expect(kind.executable == "iw3sp.exe" && kind.folder == "CoD4" && kind.usesGameDrive)
      #expect(kind.preservedConfiguration == ["mtld3d.conf"])
    case .farcry2: #expect(kind.usesGameDrive)
    }
  }

  @Test
  func `far cry 2 uses the bundled renderer and no NFS input plugin`() throws {
    let paths = try AppPaths(
      bundle: URL(fileURLWithPath: "/Applications/Far Cry 2.app"),
      support: URL(fileURLWithPath: "/tmp/FarCry2 Player"), game: .farcry2)
    let environment = LaunchEnvironment.make(
      paths: paths, prefix: paths.prefix, home: paths.support, temporary: paths.support)
    #expect(
      environment["WINEDLLPATH"]
        == "/Applications/Far Cry 2.app/Contents/SharedSupport/Wine/lib/wine/d3d9/mtld3d")
    #expect(environment["WINEDLLOVERRIDES"] == "mscoree,mshtml=")
    #expect(environment["WINE_COMPATDB"]?.contains("d3d9=mtld3d") == true)
    #expect(
      environment["ROSETTA_X87_PATH"] == "/Applications/Far Cry 2.app/Contents/Helpers/x87sidecar")
    #expect(paths.session.lastPathComponent == "FarCry2Session")
  }
}

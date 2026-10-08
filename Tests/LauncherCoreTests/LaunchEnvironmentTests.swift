import Foundation
import Testing

@testable import LauncherCore

struct LaunchEnvironmentTests {
  @Test
  func `cod4 uses bundled renderer without loading NFS input plugins`() throws {
    let paths = try AppPaths(
      bundle: URL(fileURLWithPath: "/Applications/Call of Duty.app"),
      support: URL(fileURLWithPath: "/tmp/CoD4 Player"), game: .cod4)
    let environment = try LaunchEnvironment.make(
      paths: paths, prefix: paths.prefix, home: paths.support, temporary: paths.support)
    #expect(
      environment["WINEDLLPATH"]
        == "/Applications/Call of Duty.app/Contents/SharedSupport/Wine/lib/wine/d3d9/mtld3d")
    #expect(environment["WINEDLLOVERRIDES"] == "mscoree,mshtml=")
    #expect(environment["MTL_HUD_ENABLED"] == "0")
    #expect(environment["WINE_COMPATDB"]?.contains("d3d9=mtld3d") == true)
  }
  @Test(arguments: ["/Applications/Most Wanted.app", "/tmp/Friends & games/НФС.app"])
  func `resolves runtime paths after moving the app`(location: String) throws {
    let sut = try AppPaths(
      bundle: URL(fileURLWithPath: location),
      support: URL(fileURLWithPath: "/tmp/Player Data"))
    #expect(sut.wine.path == location + "/Contents/SharedSupport/Wine/bin/wine")
    #expect(sut.game(version: "v1").path == "/tmp/Player Data/Data/Versions/v1/Game")
  }

  @Test
  func `does not inherit profiling or injected libraries`() throws {
    let sut = try AppPaths(
      bundle: URL(fileURLWithPath: "/tmp/Game.app"),
      support: URL(fileURLWithPath: "/tmp/Player"))
    let environment = try LaunchEnvironment.make(
      paths: sut, prefix: sut.prefix,
      home: URL(fileURLWithPath: "/Users/friend"), temporary: URL(fileURLWithPath: "/tmp"))
    #expect(environment["HOME"] == "/Users/friend")
    #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
    #expect(environment["ROSETTA_X87_PATH"] == "/tmp/Game.app/Contents/Helpers/x87sidecar")
    #expect(environment["WINEPREFIX"] == sut.prefix.path)
    #expect(environment["WINEDLLOVERRIDES"] == "dinput8=n,b;mscoree,mshtml=")
    #expect(environment.keys.allSatisfy { !$0.hasPrefix("X87_") && !$0.hasPrefix("DYLD_") })
  }

  @Test(arguments: ["/tmp/Game.app", "/tmp/Game.app/Contents/State"])
  func `rejects writable state inside the bundle`(support: String) {
    #expect(throws: LauncherError.self) {
      try AppPaths(
        bundle: URL(fileURLWithPath: "/tmp/Game.app"),
        support: URL(fileURLWithPath: support))
    }
  }

  private func environment(
    debugChannels: String = LaunchEnvironment.silentDebugChannels, usesSidecar: Bool = true
  ) throws -> [String: String] {
    let sut = try AppPaths(
      bundle: URL(fileURLWithPath: "/tmp/Game.app"), support: URL(fileURLWithPath: "/tmp/Player"),
      game: .nfs2015)
    return try LaunchEnvironment.make(
      paths: sut, prefix: sut.prefix, home: URL(fileURLWithPath: "/tmp/Home"),
      temporary: URL(fileURLWithPath: "/tmp"), debugChannels: debugChannels,
      usesSidecar: usesSidecar)
  }

  @Test
  func `is silent by default and carries the sidecar`() throws {
    let plain = try environment()
    #expect(plain["WINEDEBUG"] == "-all")
    #expect(plain["ROSETTA_X87_PATH"] == "/tmp/Game.app/Contents/Helpers/x87sidecar")
  }

  @Test
  func `passes a diagnostic channel list through and nothing else changes`() throws {
    let plain = try environment()
    let diagnostic = try environment(debugChannels: "err+all,fixme-all,+seh")
    #expect(diagnostic["WINEDEBUG"] == "err+all,fixme-all,+seh")
    var rest = diagnostic
    rest["WINEDEBUG"] = "-all"
    #expect(rest == plain)
  }

  @Test(arguments: ["", "+seh;id", "+SEH", "all -x", "a\nb"])
  func `refuses a debug channel list that is not one`(list: String) {
    #expect(throws: LauncherError.self) { try environment(debugChannels: list) }
  }

  @Test
  func `leaves the sidecar variable out when the game turns it off, and changes nothing else`()
    throws
  {
    let plain = try environment()
    var without = try environment(usesSidecar: false)
    #expect(without["ROSETTA_X87_PATH"] == nil)
    without["ROSETTA_X87_PATH"] = plain["ROSETTA_X87_PATH"]
    #expect(without == plain)
  }
}

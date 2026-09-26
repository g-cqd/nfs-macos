import Foundation
import Testing

@testable import LauncherCore

struct LaunchEnvironmentTests {
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
    let environment = LaunchEnvironment.make(
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
}

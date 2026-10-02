import Foundation
import LauncherCore
import Testing

@testable import FarCry2Session

struct SessionOptionsTests {
  private let app = "/Applications/Far Cry 2.app"

  @Test
  func `parses each operation with its support folder`() throws {
    let prepare = try SessionOptions(arguments: [app, "--support", "/tmp/Player", "--prepare"])
    #expect(prepare.action == .prepare && prepare.request == nil)
    #expect(prepare.support.path == "/tmp/Player" && prepare.bundle.path == app)
    let play = try SessionOptions(
      arguments: [app, "--support", "/tmp/Player", "--play", "--request", "/tmp/r.json"])
    #expect(play.action == .play && play.request?.path == "/tmp/r.json")
    for flag in ["--configure", "--backups", "--import-game"] {
      let options = try SessionOptions(
        arguments: [app, "--support", "/tmp/Player", flag, "--request", "/tmp/x"])
      #expect(options.action.rawValue == flag)
    }
  }

  @Test(arguments: [
    [], ["not-an-app", "--support", "/tmp/p", "--prepare"],
    ["/A.app", "--prepare"], ["/A.app", "--support", "/tmp/p"],
    ["/A.app", "--support", "/tmp/p", "--prepare", "--play"],
    ["/A.app", "--support", "/tmp/p", "--support", "/tmp/q", "--prepare"],
    ["/A.app", "--support", "/tmp/p", "--play"],
    ["/A.app", "--support", "/tmp/p", "--configure"],
    ["/A.app", "--support", "/tmp/p", "--prepare", "--request"],
    ["/A.app", "--support", "/tmp/p", "--prepare", "--mode", "x"],
    ["/A.app", "--support", "/tmp/p", "--prepare", "--request", "a", "--request", "b"],
    ["/A.app", "--support"],
  ])
  func `rejects missing, repeated and unknown options`(arguments: [String]) {
    #expect(throws: LauncherError.self) { try SessionOptions(arguments: arguments) }
  }
}

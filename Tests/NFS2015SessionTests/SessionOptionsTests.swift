import Foundation
import LauncherCore
import Testing

@testable import NFS2015Session

struct SessionOptionsTests {
  private let app = "/Applications/Need for Speed.app"

  @Test
  func `parses each operation with its support folder`() throws {
    for flag in ["--prepare", "--play", "--enable-controller", "--open-client"] {
      let options = try SessionOptions(arguments: [app, "--support", "/tmp/Player", flag])
      #expect(options.action == flag && options.request == nil)
      #expect(options.bundle.path == app && options.support.path == "/tmp/Player")
    }
    for flag in ["--configure", "--choose-installation", "--install-client", "--configure-metalfx"]
    {
      let options = try SessionOptions(
        arguments: [app, "--support", "/tmp/Player", flag, "--request", "/tmp/request"])
      #expect(options.action == flag && options.request?.path == "/tmp/request")
    }
  }

  @Test(arguments: [
    [], ["not-an-app", "--support", "/tmp/p", "--prepare"], ["/A.app", "--prepare"],
    ["/A.app", "--support", "/tmp/p"], ["/A.app", "--support", "/tmp/p", "--prepare", "--play"],
    ["/A.app", "--support", "/tmp/p", "--open-client", "--install-client", "--request", "x"],
    ["/A.app", "--support", "/tmp/p", "--install-client"],
    ["/A.app", "--support", "/tmp/p", "--configure"],
    ["/A.app", "--support", "/tmp/p", "--configure-metalfx"],
    ["/A.app", "--support", "/tmp/p", "--choose-installation"],
    ["/A.app", "--support", "/tmp/p", "--install-client", "--request"],
    ["/A.app", "--support", "/tmp/p", "--install-client", "--request", "a", "--request", "b"],
    ["/A.app", "--support", "/tmp/p", "--support", "/tmp/q", "--prepare"],
    ["/A.app", "--support", "/tmp/p", "--prepare", "--launch"],
    ["/A.app", "--support"],
  ])
  func `rejects missing, repeated and unknown options`(arguments: [String]) {
    #expect(throws: LauncherError.self) { try SessionOptions(arguments: arguments) }
  }
}

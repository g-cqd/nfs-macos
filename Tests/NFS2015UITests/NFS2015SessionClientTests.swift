import Foundation
import NFS2015Core
import Testing

@testable import NFS2015Launcher

struct NFS2015SessionClientTests {
  private let folder = URL(fileURLWithPath: "/Windows")

  @Test
  func `gives each operation the helper flag it is run with`() {
    let flags: [(NFS2015Operation, String)] = [
      (.prepare, "--prepare"), (.play, "--play"), (.enableController, "--enable-controller"),
      (.chooseInstallation(folder), "--choose-installation"),
      (.installClient(folder), "--install-client"), (.openClient, "--open-client"),
      (.configureMetalFX(NFS2015MetalFXRequest(action: .reset)), "--configure-metalfx"),
      (.configureDiagnostics(NFS2015DiagnosticsRequest(action: .reset)), "--configure-diagnostics"),
      (
        .configure(
          NFS2015SettingsRequest(action: .restoreOriginal, changes: [:], expectedDigest: "d")),
        "--configure"
      ),
    ]
    for (operation, flag) in flags {
      #expect(NFS2015SessionClient.flag(for: operation) == flag)
    }
    #expect(Set(flags.map(\.1)).count == flags.count)
  }
}

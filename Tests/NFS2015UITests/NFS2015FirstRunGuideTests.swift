import Foundation
import LauncherCore
import NFS2015Core
import SharedLauncher
import Testing

@testable import NFS2015Launcher

@MainActor
struct NFS2015FirstRunGuideTests {
  private func model(setup: NFS2015Setup?, owns: Bool = true) -> NFS2015Model {
    let service = NFS2015ModelTests.FakeService(
      snapshot: NFS2015Snapshot(
        blocker: setup == nil ? nil : "Open the EA app.", clientVersion: "13.796.0.6309",
        installedAt: "/Player/Data/Prefix", hasOptionsFile: false,
        ownsWindowsFolder: owns ? true : nil, setup: setup))
    return NFS2015Model(
      service: service,
      rosetta: RosettaSetup(service: NFS2015ModelTests.FakeRosetta(available: true)),
      carriesGame: owns)
  }

  @Test
  func `tells the player to wait, sign in and play, and names both outside prompts`() {
    let steps = NFS2015FirstRunGuide.steps
    #expect(steps.map(\.title) == ["Wait for the first start", "Sign in to EA", "Press Play"])
    let text = steps.map(\.detail).joined(separator: " ")
    #expect(text.contains("microphone") && text.contains("activate"))
    #expect(text.contains("never sees, stores or copies your sign-in"))
    #expect(!text.contains("ea.com") && !text.lowercased().contains("download"))
  }

  @Test(arguments: [
    ("/Applications/Need for Speed Bundled.app", false),
    ("/Users/player/Downloads/Need for Speed Bundled.app", false),
    ("/private/var/folders/xy/T/AppTranslocation/1234-ABCD/d/Need for Speed Bundled.app", true),
    ("/private/var/folders/xy/T/AppTranslocation", true),
    ("/Users/player/AppTranslocationNotes/Need for Speed.app", false),
  ])
  func `recognizes an app that macOS runs from a temporary translocated copy`(
    path: String, translocated: Bool
  ) {
    #expect(NFS2015FirstRunGuide.isTranslocated(URL(fileURLWithPath: path)) == translocated)
    #expect(NFS2015FirstRunGuide(bundle: URL(fileURLWithPath: path)).translocated == translocated)
  }

  @Test
  func `explains how to stop the slow translocated first start`() {
    let notice = NFS2015FirstRunGuide.translocationNotice
    #expect(notice.contains("xattr -dr com.apple.quarantine"))
    #expect(notice.contains("Applications folder"))
  }

  @Test
  func `shows the checklist until the player has signed in, and never in an import app`() async {
    let waiting = model(setup: .signIn)
    await waiting.run()
    #expect(waiting.needsFirstRunGuide)
    let missing = model(setup: .installClient)
    await missing.run()
    #expect(missing.needsFirstRunGuide)
    let signedIn = model(setup: nil)
    await signedIn.run()
    #expect(!signedIn.needsFirstRunGuide)
    let importing = model(setup: nil, owns: false)
    await importing.run()
    #expect(!importing.needsFirstRunGuide)
  }

  @Test
  func `says the EA app is set up while the first start runs, and that it keeps the old wording`() {
    let preparing = model(setup: .signIn)
    #expect(preparing.statusMessage.contains("creating its Windows folder"))
    #expect(preparing.statusMessage.contains("EA app that comes with it"))
  }
}

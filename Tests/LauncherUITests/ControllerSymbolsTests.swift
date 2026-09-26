import AppKit
import LauncherCore
import Testing

@testable import NFSMWLauncher

@MainActor
struct ControllerSymbolsTests {
  @Test(arguments: [false, true])
  func `each binding has a supported symbol and a spoken label`(playStation: Bool) {
    for binding in ControllerMappings.buttons {
      let sut = ControllerButtonPresentation(binding: binding, playStation: playStation)
      #expect(!sut.title.isEmpty)
      #expect(NSImage(systemSymbolName: sut.symbol, accessibilityDescription: sut.title) != nil)
    }
  }

  @Test func `analog trigger labels match the selected controller family`() throws {
    let trigger = try #require(ControllerMappings.buttons.first { $0.id == "XINPUT_GAMEPAD_RT" })
    let xbox = ControllerButtonPresentation(binding: trigger, playStation: false)
    let playStation = ControllerButtonPresentation(binding: trigger, playStation: true)
    #expect(xbox.symbol == "rt.button.roundedtop.horizontal")
    #expect(playStation.symbol == "r2.button.roundedtop.horizontal")
    #expect(xbox.title.contains("analog"))
    #expect(playStation.title.contains("analog"))
    #expect(GameSettings().value("hud") == "0")
  }
}

import Foundation
import Testing

@testable import LauncherCore

struct SettingsTests {
  @Test(arguments: ["-1", ""])
  func `reads the plugins unbound controller values`(value: String) throws {
    let sut = try ControllerMappings(text: "[Events]\nGAMEACTION_NOS = \(value)\n")
    #expect(sut.value(for: "GAMEACTION_NOS") == "NONE")
  }
  @Test func `resolution choices are complete pairs grouped by aspect ratio`() throws {
    #expect(
      ResolutionPreset.all.contains {
        $0.width == 1680 && $0.height == 1050 && $0.ratio == .wide16to10
      })
    #expect(
      ResolutionPreset.all.contains {
        $0.width == 1920 && $0.height == 1080 && $0.ratio == .wide16to9
      })
    for preset in ResolutionPreset.all {
      var settings = GameSettings()
      settings.values["width"] = String(preset.width)
      settings.values["height"] = String(preset.height)
      try settings.validate()
    }
    var invalid = GameSettings()
    invalid.values["width"] = "7681"
    invalid.values["height"] = "1050"
    #expect(throws: LauncherError.self) { try invalid.validate() }
  }

  @Test func `changing aspect ratio picks a nearby preset height`() throws {
    let choice = try #require(ResolutionPreset.nearest(ratio: .wide16to9, height: 1050))
    #expect(choice.width == 1920 && choice.height == 1080)
  }
  @Test func `defaults retain the shipped quality and analog controls`() throws {
    let sut = GameSettings()
    try sut.validate()
    #expect(sut.value("fps") == "120")
    #expect(sut.value("scale") == "1")
    #expect(sut.mappings.value(for: "GAMEACTION_GAS") == "XINPUT_GAMEPAD_RT")
    #expect(sut.mappings.value(for: "GAMEACTION_BRAKE") == "XINPUT_GAMEPAD_LT")
  }

  @Test(arguments: ["-1", "nan", "0.1", "1.1", "\nrender.scale = 0.5"])
  func `rejects unsupported scale values`(value: String) {
    var sut = GameSettings()
    sut.values["scale"] = value
    #expect(throws: LauncherError.self) { try sut.validate() }
  }

  @Test func `rejects unknown settings and invalid controller commands`() {
    var sut = GameSettings()
    sut.values["invented"] = "1"
    #expect(throws: LauncherError.self) { try sut.validate() }
    sut = GameSettings()
    sut.mappings.bindings["GAMEACTION_GAS"] = "XINPUT_GAMEPAD_INVENTED"
    #expect(throws: LauncherError.self) { try sut.validate() }
  }

  @Test func `updates only the selected INI section and normalizes duplicate keys`() throws {
    var sut = try ConfigText(
      "; retain me\r\n[Graphics]\r\nQuality = 1 ; old\r\nQuality=0\r\n[Other]\r\nQuality=2\r\n")
    sut.set(section: "Graphics", key: "Quality", value: "3")
    let text = sut.text
    #expect(text.contains("; retain me"))
    #expect(text.contains("[Graphics]\nQuality = 3\n"))
    #expect(text.contains("[Other]\nQuality=2"))
    #expect(!text.contains("Quality=0"))
  }

  @Test func `mapping edits preserve keyboard and unrelated controller actions`() throws {
    let original =
      "[Events]\nGAMEACTION_GAS = XINPUT_GAMEPAD_RT\nDEBUGACTION_TURBO = XINPUT_GAMEPAD_LT\n[EventsKB]\nGAMEACTION_GAS = VK_UP\n"
    var bindings = ControllerMappings()
    bindings.bindings["GAMEACTION_GAS"] = "XINPUT_GAMEPAD_LT"
    let sut = try bindings.applying(to: original)
    #expect(sut.contains("GAMEACTION_GAS = XINPUT_GAMEPAD_LT"))
    #expect(sut.contains("DEBUGACTION_TURBO = XINPUT_GAMEPAD_LT"))
    #expect(sut.contains("[EventsKB]\nGAMEACTION_GAS = VK_UP"))
  }

  @Test func `registry edits preserve unrelated keys and encode custom resolution`() throws {
    var settings = GameSettings()
    settings.values["width"] = "1920"
    settings.values["height"] = "1080"
    let sut = try ConfigurationPlan.registry(
      "WINE REGISTRY Version 2\n\n[Software\\\\Unrelated] 1\n\"Value\"=dword:00000009\n",
      settings: settings)
    #expect(sut.contains("\"g_RacingResolution\"=dword:87800438"))
    #expect(sut.contains("\"Value\"=dword:00000009"))
    #expect(sut.contains("\"RetinaMode\"=\"N\""))
  }

  @Test func `incompatible antialiasing is rejected`() {
    var sut = GameSettings()
    sut.values["smaa"] = "1"
    #expect(throws: LauncherError.self) { try sut.validate() }
    sut.values["msaa"] = "0"
    #expect(throws: Never.self) { try sut.validate() }
  }
}

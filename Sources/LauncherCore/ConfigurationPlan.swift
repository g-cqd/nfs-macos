import Foundation

package enum ConfigurationPlan {
  package static let widePath = "scripts/NFSMostWanted.WidescreenFix.ini"
  package static let inputPath = "scripts/NFS_XtendedInput.ini"
  package static let defaultMapPath = "scripts/NFS_XtendedInput.default.ini"
  private static let gameSection = "Software\\\\EA Games\\\\Need for Speed Most Wanted"

  package static func registry(_ text: String, settings: GameSettings) throws(LauncherError)
    -> String
  {
    try settings.validate()
    guard text.hasPrefix("WINE REGISTRY Version 2"),
      let width = UInt32(settings.value("width")), let height = UInt32(settings.value("height"))
    else { throw .operation("Unsupported Wine registry or resolution.") }
    var ini = try ConfigText(text)
    for definition in GameSettings.definitions where definition.destination == .registry {
      guard let value = UInt32(settings.value(definition.id)) else {
        throw .operation("Invalid registry value.")
      }
      ini.set(
        section: gameSection, key: "\"\(definition.key)\"",
        value: String(format: "dword:%08x", value), compact: true)
    }
    ini.set(
      section: gameSection, key: "\"g_RacingResolution\"",
      value: String(format: "dword:%08x", 0x8000_0000 | width << 16 | height), compact: true)
    ini.set(
      section: "Software\\\\Wine\\\\Mac Driver", key: "\"RetinaMode\"",
      value: settings.value("retina") == "1" ? "\"Y\"" : "\"N\"", compact: true)
    return ini.text + "\n"
  }

  package static func config(
    _ text: String, destination: SettingDefinition.Destination, settings: GameSettings
  ) throws(LauncherError) -> String {
    try settings.validate()
    var ini = try ConfigText(text)
    for definition in GameSettings.definitions where definition.destination == destination {
      ini.set(
        section: definition.section, key: definition.key, value: settings.value(definition.id))
    }
    if destination == .widescreen {
      ini.set(section: "MAIN", key: "ResX", value: settings.value("width"))
      ini.set(section: "MAIN", key: "ResY", value: settings.value("height"))
      ini.set(section: "MISC", key: "SimRate", value: "120")
      ini.set(
        section: "GRAPHICS", key: "DisableMotionBlur",
        value: settings.value("motionBlur") == "0" ? "1" : "0")
    }
    return ini.text + "\n"
  }

  package static func mappingPath(profile: String) throws(LauncherError) -> String {
    if profile.isEmpty { return defaultMapPath }
    guard ProfileName.isValid(profile) else { throw .operation("Invalid mapping profile.") }
    return "scripts/XtendedInputMaps/\(profile)/NFS_XtendedInput.usermap.ini"
  }
}

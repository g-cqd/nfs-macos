import Foundation

package struct GameSettings: Codable, Equatable, Sendable {
  package var values: [String: String] = [:]
  package var mappings = ControllerMappings()
  package var mappingProfile = ""
  package var mappingEdits: [String: ControllerMappings] = [:]
  package var unlockAll = true
  package static let definitions = GraphicsCatalog.settings + ControlsCatalog.settings

  package init() {}

  package func value(_ id: String) -> String {
    values[id] ?? Self.definitions.first { $0.id == id }?.defaultValue ?? ""
  }

  package func validate() throws(LauncherError) {
    guard values.count <= Self.definitions.count,
      values.keys.allSatisfy({ key in Self.definitions.contains { $0.id == key } })
    else { throw .operation("The settings contain an unknown option.") }
    for definition in Self.definitions where !definition.accepts(value(definition.id)) {
      throw .operation("Invalid value for \(definition.title).")
    }
    guard value("smaa") != "1" || value("msaa") == "0" else {
      throw .operation("Disable multisample antialiasing before enabling SMAA.")
    }
    guard mappingProfile.isEmpty || ProfileName.isValid(mappingProfile) else {
      throw .operation("Invalid controller profile name.")
    }
    try mappings.validate()
    guard mappingEdits.count <= 100 else {
      throw .operation("Too many edited controller profiles.")
    }
    for (profile, mappings) in mappingEdits {
      guard profile.isEmpty || ProfileName.isValid(profile) else {
        throw .operation("Invalid controller profile name.")
      }
      try mappings.validate()
    }
  }
}

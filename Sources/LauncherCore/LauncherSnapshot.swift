import Foundation

package struct LauncherSnapshot: Codable, Sendable {
  package var settings: GameSettings
  package var mappings: [String: ControllerMappings]
  package var profiles: [ProfileSummary]

  package static func read(paths: AppPaths) throws(LauncherError) -> Self {
    let store = SettingsStore(paths: paths)
    var settings = try store.load()
    var mappings: [String: ControllerMappings] = ["": try store.mapping(profile: "")]
    for profile in try store.mappingProfiles() {
      mappings[profile] = try store.mapping(profile: profile)
    }
    settings.mappings = try store.mapping(profile: settings.mappingProfile)
    let profiles = try SaveStore(paths: paths).profiles()
    for profile in profiles where mappings[profile.id] == nil {
      mappings[profile.id] = try store.mapping(profile: profile.id)
    }
    return Self(settings: settings, mappings: mappings, profiles: profiles)
  }

  package func write(paths: AppPaths) throws {
    try JSONEncoder().encode(self).write(
      to: paths.support.appendingPathComponent("launcher-state.json"), options: .atomic)
  }
}

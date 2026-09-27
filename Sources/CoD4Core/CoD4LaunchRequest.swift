/// A validated configuration applied before a selected game session.
package struct CoD4LaunchRequest: Codable, Sendable {
  package let settings: CoD4Settings
  package let profile: String
  package let mode: CoD4Mode
  package init(settings: CoD4Settings, profile: String, mode: CoD4Mode) {
    self.settings = settings
    self.profile = profile
    self.mode = mode
  }
}

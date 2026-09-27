/// Last committed launcher state, published after preparation or session completion.
package struct CoD4Snapshot: Codable, Sendable {
  package let settings: CoD4Settings
  package let profiles: [CoD4Profile]
  package let selectedProfile: String
  package init(settings: CoD4Settings, profiles: [CoD4Profile], selectedProfile: String) {
    self.settings = settings
    self.profiles = profiles
    self.selectedProfile = selectedProfile
  }
}

/// A player profile and its restorable local backups.
package struct CoD4Profile: Codable, Sendable, Identifiable {
  package let name: String
  package let hasCampaignSave: Bool
  package let isInstalled: Bool
  package let backupNames: [String]
  package var id: String { name }
  package init(name: String, hasCampaignSave: Bool, backupNames: [String], isInstalled: Bool = true)
  {
    self.name = name
    self.hasCampaignSave = hasCampaignSave
    self.backupNames = backupNames
    self.isInstalled = isInstalled
  }
}

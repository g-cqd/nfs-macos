package struct ProfileSummary: Codable, Identifiable, Sendable {
  package let id: String
  package let fingerprint: String
  package let cash: UInt32?
  package let cars: [GarageCar]
  package let backups: [String]
  package let issue: String?
  package var displayName: String { isRemoved ? id + " (removed)" : id }
  package var isRemoved: Bool { fingerprint.isEmpty }
}

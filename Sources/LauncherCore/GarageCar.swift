package struct GarageCar: Codable, Identifiable, Sendable {
  package let id: Int
  package let name: String
  package let signature: String
  package let partsSlot: Int
  package let careerSlot: Int
  package let levels: [UInt32]
  package let junkman: UInt32
  package let heat: Float
  package let bounty: UInt32
  package var limits: [UInt32]? { CarModel.all[signature]?.limits }
  package static let partNames = [
    "Tires", "Brakes", "Suspension", "Transmission", "Engine", "Turbo", "Nitrous",
  ]
}

package enum SaveCheat: Codable, Sendable {
  case money(operation: MoneyOperation, amount: UInt64)
  case car(car: Int, levels: [UInt32], junkman: UInt32, heat: Float, bounty: UInt32)
  case addCar(signature: String, count: Int)
  case duplicate(car: Int, count: Int)
}

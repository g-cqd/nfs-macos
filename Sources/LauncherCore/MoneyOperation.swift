package enum MoneyOperation: String, Codable, CaseIterable, Sendable {
  case set = "Set"
  case add = "Add"
  case subtract = "Subtract"
  case multiply = "Multiply"

  package func result(current: UInt32, amount: UInt64) throws(LauncherError) -> UInt32 {
    let value = UInt64(current)
    let result: (partialValue: UInt64, overflow: Bool)
    switch self {
    case .set: result = (amount, false)
    case .add: result = value.addingReportingOverflow(amount)
    case .subtract: result = value.subtractingReportingOverflow(amount)
    case .multiply: result = value.multipliedReportingOverflow(by: amount)
    }
    guard !result.overflow, result.partialValue <= UInt32.max else {
      throw .operation("Cash must remain between 0 and 4,294,967,295.")
    }
    return UInt32(result.partialValue)
  }
}

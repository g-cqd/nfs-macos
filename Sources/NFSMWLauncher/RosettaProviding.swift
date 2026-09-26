@MainActor
protocol RosettaProviding {
  func isAvailable() async throws -> Bool
  func requestInstallation() async throws
}

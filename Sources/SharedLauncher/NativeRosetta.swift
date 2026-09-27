import AppKit
import Foundation

@MainActor
package struct NativeRosetta: RosettaProviding {
  package init() {}
  /// Probes actual Intel execution without opening an installer or polling a receipt.
  package func isAvailable() async throws -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
    process.arguments = ["-x86_64", "/usr/bin/true"]
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let (events, continuation) = AsyncStream<Int32>.makeStream(bufferingPolicy: .bufferingNewest(1))
    process.terminationHandler = { child in
      continuation.yield(child.terminationStatus)
      continuation.finish()
    }
    defer {
      if process.isRunning { process.terminate() }
      process.terminationHandler = nil
      continuation.finish()
    }
    try Task.checkCancellation()
    try process.run()
    for await status in events {
      try Task.checkCancellation()
      return status == 0
    }
    throw CancellationError()
  }

  /// Launch Services requests Apple's Rosetta installation before opening this Intel-only helper.
  package func requestInstallation() async throws {
    let helper = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/Rosetta Request.app")
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.createsNewApplicationInstance = true
    _ = try await NSWorkspace.shared.openApplication(at: helper, configuration: configuration)
  }
}

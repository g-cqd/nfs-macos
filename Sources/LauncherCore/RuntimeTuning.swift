import Foundation

/// Runtime switches a recipe declares for its Wine build, rather than compiling them in.
///
/// Need for Speed (2015) needs a Wine build that delivers x86 hardware execution
/// breakpoints. That delivery is gated at run time by `WINE_TF_EMULATION`, with
/// `WINE_TF_MAX_STEPS` and `WINE_TF_MAX_NS` bounding its single-step fallback. A build
/// without the gate ignores the variables, so the same bundle works with either runtime.
package struct RuntimeTuning: Codable, Equatable, Sendable {
  /// Only these names may reach a child process; nothing else is forwarded or inherited.
  package static let supportedNames = [
    "WINE_TF_EMULATION", "WINE_TF_MAX_STEPS", "WINE_TF_MAX_NS",
  ]
  private let values: [String: String]

  package init(_ values: [String: String] = [:]) { self.values = values }

  package init(from decoder: any Decoder) throws {
    values = try [String: String](from: decoder)
  }

  package func encode(to encoder: any Encoder) throws { try values.encode(to: encoder) }

  /// Rejects an unsupported name or a value that is not a bounded decimal count.
  package func validate() throws(LauncherError) {
    guard values.count <= Self.supportedNames.count else {
      throw .operation("The bundle declares too many runtime switches.")
    }
    for (name, value) in values {
      guard Self.supportedNames.contains(name) else {
        throw .operation("The bundle declares an unsupported runtime switch: \(name).")
      }
      guard !value.isEmpty, value.utf8.count <= 20,
        value.utf8.allSatisfy({ (48...57).contains($0) })
      else {
        throw .operation("Runtime switch \(name) must be a decimal count.")
      }
    }
  }

  /// The validated entries, for merging into an explicitly constructed environment.
  package func environment() throws(LauncherError) -> [String: String] {
    try validate()
    return values
  }
}

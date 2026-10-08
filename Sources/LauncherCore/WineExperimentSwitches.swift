import Foundation

/// The environment switches of Wine patch 0007 that an app may hand to a Wine session, and the
/// check that nothing else gets through under their cover.
///
/// They are experiments for finding out why a game faults on a Rosetta runtime; each is off unless
/// set. `WINE_ROSETTA_FLUSH_TOGGLE=1` and `WINE_ROSETTA_PROTECT_TOGGLE=1` make the runtime
/// round-trip the protection of executable pages after an instruction-cache flush, or after a
/// protection change that gives execute. `WINE_TRACE_PAGE=<hexstart>-<hexend>` makes it print a
/// `wine-trace:` line for each memory call that touches the window. A runtime without the patch
/// ignores all three.
package enum WineExperimentSwitches {
  package static let flushToggle = "WINE_ROSETTA_FLUSH_TOGGLE"
  package static let protectToggle = "WINE_ROSETTA_PROTECT_TOGGLE"
  package static let tracePage = "WINE_TRACE_PAGE"
  package static let names = [flushToggle, protectToggle, tracePage]

  /// The page window the starter's trace switch uses: the 4 KiB page `0x1B30000` where the
  /// game's fault of 2026-10-07 and 2026-10-08 happened.
  package static let presetTraceWindow = "1B30000-1B31000"

  /// Whether the text is `<start>-<end>` in hexadecimal, each 1 to 16 digits, with the end above
  /// the start. This is the form the runtime reads; anything else it silently ignores.
  package static func isTraceWindow(_ text: String) -> Bool {
    let parts = text.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, parts.allSatisfy({ (1...16).contains($0.count) }),
      parts.allSatisfy({ $0.allSatisfy(\.isHexDigit) }),
      let start = UInt64(parts[0], radix: 16), let end = UInt64(parts[1], radix: 16)
    else { return false }
    return end > start
  }

  /// Rejects a name that is not one of the three and a value the runtime would not accept.
  package static func validate(_ values: [String: String]) throws(LauncherError) {
    for (name, value) in values {
      guard names.contains(name) else {
        throw .operation("Unsupported Wine experiment switch: \(name).")
      }
      if name == tracePage {
        guard isTraceWindow(value) else {
          throw .operation("\(name) must be <hexstart>-<hexend> with the end above the start.")
        }
      } else if value != "1" {
        throw .operation("\(name) must be 1 or left out.")
      }
    }
  }
}

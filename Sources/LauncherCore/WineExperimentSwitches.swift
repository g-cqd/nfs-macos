import Foundation

/// The environment switches of Wine patches 0007 and 0008 that an app may hand to a Wine session,
/// and the check that nothing else gets through under their cover.
///
/// They are experiments for finding out why a game faults on a Rosetta runtime; each is off unless
/// set. `WINE_ROSETTA_FLUSH_TOGGLE=1` and `WINE_ROSETTA_PROTECT_TOGGLE=1` make the runtime
/// round-trip the protection of executable pages after an instruction-cache flush, or after a
/// protection change that gives execute. `WINE_TRACE_PAGE=<hexstart>-<hexend>` makes it print a
/// `wine-trace:` line for each memory call that touches the window. `WINE_RWX_WX_EMULATION=1`
/// (patch 0008) makes the runtime keep private read-write-execute pages non-writable and let each
/// store through one instruction at a time, which works around a Rosetta 2 defect with code that
/// is built by stores right ahead of the instruction pointer; `WINE_RWX_WX_HOT_LIMIT=<n>` tunes
/// when a page that is written very often is released (0 never). A runtime without a patch
/// ignores its switches.
package enum WineExperimentSwitches {
  package static let flushToggle = "WINE_ROSETTA_FLUSH_TOGGLE"
  package static let protectToggle = "WINE_ROSETTA_PROTECT_TOGGLE"
  package static let tracePage = "WINE_TRACE_PAGE"
  package static let rwxWxEmulation = "WINE_RWX_WX_EMULATION"
  /// Stores per 100 ms after which the runtime stops emulating one page; only a developer sets it.
  package static let rwxHotLimit = "WINE_RWX_WX_HOT_LIMIT"
  package static let names = [flushToggle, protectToggle, tracePage, rwxWxEmulation, rwxHotLimit]

  /// Whether the text is a decimal count of at most seven digits, the form the hot limit takes.
  package static func isHotLimit(_ text: String) -> Bool {
    (1...7).contains(text.utf8.count) && text.utf8.allSatisfy { (48...57).contains($0) }
  }

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
      } else if name == rwxHotLimit {
        guard isHotLimit(value) else {
          throw .operation("\(name) must be a decimal number of at most seven digits.")
        }
      } else if value != "1" {
        throw .operation("\(name) must be 1 or left out.")
      }
    }
  }
}

import Foundation

/// Whether the Mac is so short of memory that the EA app and the game cannot be expected to start.
///
/// Measured on 2026-10-03: with swap 94 percent used (17.8 of 18.4 GB) and the volume holding the
/// swap files almost full, the EA app took 36 s to sign in instead of 8 s, its interface stalled for
/// seconds at a time, and the game process stayed alive for minutes without drawing a window. The
/// app cannot cure that, but it can say so instead of leaving the player with a blank screen.
package struct MemoryPressure: Equatable, Sendable {
  /// Swap in use, in bytes, and the swap size macOS has made so far.
  package let swapUsed: UInt64
  package let swapTotal: UInt64

  package init(swapUsed: UInt64, swapTotal: UInt64) {
    self.swapUsed = swapUsed
    self.swapTotal = swapTotal
  }

  /// At least this much swap in use, and at least `fraction` of the swap made so far.
  static let minimumUsed: UInt64 = 4 * 1_024 * 1_024 * 1_024
  static let fraction = 0.85

  package var isHeavy: Bool {
    swapTotal > 0 && swapUsed >= Self.minimumUsed
      && Double(swapUsed) / Double(swapTotal) >= Self.fraction
  }

  /// What to tell the player, nil when there is nothing to say.
  package var notice: String? {
    guard isHeavy else { return nil }
    let used = Double(swapUsed) / 1_073_741_824
    return """
      This Mac is short of memory (\(String(format: "%.1f", used)) GB of swap in use). The EA app \
      and the game start very slowly or not at all in that state. Quit other apps and heavy jobs, \
      then try again.
      """
  }

  /// The swap macOS reports now, nil when it cannot be read.
  package static func current() -> MemoryPressure? {
    var usage = xsw_usage()
    var size = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
    return MemoryPressure(swapUsed: usage.xsu_used, swapTotal: usage.xsu_total)
  }
}

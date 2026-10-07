import Darwin
import Foundation

/// The Mac the game ran on, without anything that names its owner: no host name, user name,
/// serial number, hardware or network address.
package struct NFS2015HostFacts: Equatable, Sendable {
  package var model: String
  package var chip: String
  package var memoryBytes: UInt64
  package var osVersion: String
  package var cpuCount: Int

  package init(
    model: String, chip: String, memoryBytes: UInt64, osVersion: String, cpuCount: Int
  ) {
    self.model = model
    self.chip = chip
    self.memoryBytes = memoryBytes
    self.osVersion = osVersion
    self.cpuCount = cpuCount
  }

  package var summary: String {
    let memory = String(format: "%.0f", Double(memoryBytes) / 1_073_741_824)
    return "\(model), \(chip), \(memory) GB, \(osVersion), \(cpuCount) CPUs"
  }
}

/// How busy the Mac was when a fault was seen.
package struct NFS2015LoadSample: Equatable, Sendable {
  package var loadAverages: [Double]
  /// Swap in use and swap made so far, in bytes; nil when macOS did not say.
  package var swapUsed: UInt64?
  package var swapTotal: UInt64?

  package init(loadAverages: [Double], swapUsed: UInt64?, swapTotal: UInt64?) {
    self.loadAverages = loadAverages
    self.swapUsed = swapUsed
    self.swapTotal = swapTotal
  }

  package var summary: String {
    let load = loadAverages.map { String(format: "%.2f", $0) }.joined(separator: " ")
    func gigabytes(_ bytes: UInt64) -> String {
      String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
    let swap =
      swapUsed.flatMap { used in swapTotal.map { "swap \(gigabytes(used)) of \(gigabytes($0))" } }
      ?? "swap unknown"
    return "load average \(load.isEmpty ? "unknown" : load), \(swap)"
  }
}

/// Reads the Mac. A fixture stands in for it under test.
package protocol NFS2015HostQuerying: Sendable {
  func host() -> NFS2015HostFacts
  func load() -> NFS2015LoadSample
}

package struct NFS2015SystemHost: NFS2015HostQuerying {
  package init() {}

  package func host() -> NFS2015HostFacts {
    NFS2015HostFacts(
      model: Self.text("hw.model"), chip: Self.text("machdep.cpu.brand_string"),
      memoryBytes: ProcessInfo.processInfo.physicalMemory,
      osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      cpuCount: ProcessInfo.processInfo.processorCount)
  }

  package func load() -> NFS2015LoadSample {
    var averages = [Double](repeating: 0, count: 3)
    let count = Int(getloadavg(&averages, 3))
    let swap = MemoryPressure.current()
    return NFS2015LoadSample(
      loadAverages: count > 0 ? Array(averages.prefix(count)) : [], swapUsed: swap?.swapUsed,
      swapTotal: swap?.swapTotal)
  }

  /// A short printable `sysctl` string, or `unknown`.
  static func text(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, (1...256).contains(size) else {
      return "unknown"
    }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "unknown" }
    let text = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    let printable = text.unicodeScalars.filter { (32...126).contains($0.value) }
    return printable.isEmpty ? "unknown" : String(String.UnicodeScalarView(printable.prefix(64)))
  }
}

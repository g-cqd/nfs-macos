import Darwin
import Foundation
import LauncherCore

/// Makes a connected controller visible to a game that reads XInput only.
///
/// This game loads the XInput libraries and nothing else: it has no DirectInput path. Wine's
/// bus driver only marks Xbox vendor products as gamepads, so a Sony pad reached through the
/// host's HID layer never binds to the XInput driver and the game sees no controller. Setting
/// `Hidraw` to zero for a declared device keeps Wine's SDL-backed device, which is already
/// Xbox-mapped, and the pad appears in XInput slot zero.
///
/// This writes one key per declared device into the referenced prefix's registry, which is a
/// change to a folder the app does not own. It is therefore a separate, explicit action rather
/// than something a launch performs silently.
package enum NFS2015Controller {
  /// The registry service path Wine's bus driver reads per device.
  static let service = #"HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\WineBus\Devices"#

  /// - Parameter devices: `VID/PID` pairs in four hexadecimal digits each.
  /// - Returns: A registry script for `wine reg import`.
  package static func registry(devices: [String]) throws(LauncherError) -> String {
    guard (1...32).contains(devices.count) else {
      throw .operation("This app has no controller devices to enable.")
    }
    var text = "REGEDIT4\n"
    for device in devices {
      let parts = device.split(separator: "/", omittingEmptySubsequences: false)
      guard parts.count == 2,
        parts.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isHexDigit) })
      else {
        throw .operation("Invalid controller device: \(device)")
      }
      text += "\n[\(service)\\\(parts[0].uppercased())/\(parts[1].uppercased())]\n"
      text += "\"Hidraw\"=dword:00000000\n"
    }
    return text
  }
}

/// Counts a process's live descendants, which is how a store client's readiness is observed.
package enum ProcessFamily {
  /// - Returns: The number of live descendants, bounded so a runaway tree cannot stall a wait.
  package static func descendants(of pid: Int32, limit: Int = 256) -> Int {
    var counted = 0
    var frontier = [pid]
    var seen: Set<Int32> = [pid]
    while let parent = frontier.popLast(), counted < limit {
      for child in children(of: parent) where seen.insert(child).inserted {
        counted += 1
        frontier.append(child)
        if counted >= limit { return counted }
      }
    }
    return counted
  }

  /// The command line a process shows, which for a Windows program run by Wine is the Windows
  /// path of the program; nil when the process is gone.
  package static func commandLine(of pid: Int32) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-ww", "-o", "command=", "-p", String(pid)]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = (try? pipe.fileHandleForReading.read(upToCount: 65_536)) ?? Data()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
  }

  /// Whether a live process is running the named program, such as `EADesktop.exe`.
  package static func runs(pid: Int32, program: String) -> Bool {
    commandLine(of: pid)?.lowercased().contains(program.lowercased()) == true
  }

  private static func children(of pid: Int32) -> [Int32] {
    let capacity = 256
    var buffer = [pid_t](repeating: 0, count: capacity)
    // proc_listchildpids writes at most `capacity` identifiers into this borrowed buffer.
    let bytes = buffer.withUnsafeMutableBufferPointer { storage in
      proc_listchildpids(pid, storage.baseAddress, Int32(storage.count * MemoryLayout<pid_t>.size))
    }
    guard bytes > 0 else { return [] }
    let count = min(Int(bytes) / MemoryLayout<pid_t>.size, capacity)
    return buffer.prefix(count).filter { $0 > 0 }
  }
}

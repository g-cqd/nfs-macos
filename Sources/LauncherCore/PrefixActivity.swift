import Darwin
import Foundation

/// What is running in one Wine prefix, read without starting Wine.
package enum PrefixActivity {
  /// The socket Wine's server listens on for this prefix: Wine names its folder after the
  /// prefix's device and inode, so a server of another prefix is never mistaken for this one.
  package static func serverSocket(prefix: URL, user: uid_t = getuid()) -> URL? {
    var info = stat()
    guard stat(prefix.path, &info) == 0 else { return nil }
    let folder =
      "server-\(String(UInt64(UInt32(bitPattern: info.st_dev)), radix: 16))-\(String(info.st_ino, radix: 16))"
    return URL(fileURLWithPath: "/tmp/.wine-\(user)").appendingPathComponent(folder)
      .appendingPathComponent("socket")
  }

  /// Whether this prefix's Wine server accepts a connection now.
  package static func serverIsRunning(prefix: URL) -> Bool {
    guard let socketURL = serverSocket(prefix: prefix) else { return false }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socketURL.path.utf8)
    guard path.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in path.enumerated() { buffer[index] = byte }
      buffer[path.count] = 0
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let status = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    return status == 0
  }

  /// Which of these Windows programs have a running process, by executable name only.
  ///
  /// Reads the process list once. Only the names are returned: a Windows command line can carry
  /// a one-time sign-in code, so no argument is ever kept, logged or shown.
  /// - Note: Wine processes do not name their prefix, so a program of another prefix with the
  ///   same name counts too. Stopping is always scoped to this prefix's own server.
  package static func running(_ names: [String]) -> Set<String> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axww", "-o", "args="]
    process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return matches(String(decoding: data, as: UTF8.self), names: names)
  }

  /// The names whose executable appears as a whole path component in one of the lines.
  static func matches(_ listing: String, names: [String]) -> Set<String> {
    var found = Set<String>()
    let lowered = names.map { ($0, $0.lowercased()) }
    for line in listing.lowercased().split(separator: "\n") {
      for (name, lower) in lowered where !found.contains(name) {
        var search = line[...]
        while let range = search.range(of: lower) {
          let before =
            range.lowerBound == line.startIndex ? " " : line[line.index(before: range.lowerBound)]
          let after = range.upperBound == line.endIndex ? " " : line[range.upperBound]
          if [" ", "\\", "/"].contains(before), [" ", "\""].contains(after) {
            found.insert(name)
            break
          }
          search = line[range.upperBound...]
        }
      }
    }
    return found
  }
}

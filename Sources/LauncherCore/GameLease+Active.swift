import Foundation

extension GameLease {
  /// The recorded game process, only while it is still the process that was recorded.
  package func activeProcess() -> Int32? {
    guard let data = try? BoundedFile.read(url, limit: 1024),
      let saved = try? JSONDecoder().decode(ProcessIdentity.self, from: data),
      (try? ProcessIdentity.read(pid: saved.pid)) == saved
    else { return nil }
    return saved.pid
  }
}

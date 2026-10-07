import Foundation

/// A throwaway folder for one test. Nothing outside it is touched.
struct Scratch {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  func remove() {
    // A test may have made the folder read-only on purpose.
    chmod(root.path, 0o755)
    try? FileManager.default.removeItem(at: root)
  }

  func url(_ name: String) -> URL { root.appendingPathComponent(name) }

  @discardableResult
  func write(_ name: String, _ text: String) throws -> URL {
    let target = url(name)
    try FileManager.default.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: target)
    return target
  }

  func text(_ name: String) throws -> String {
    String(decoding: try Data(contentsOf: url(name)), as: UTF8.self)
  }
}

import Foundation
import Testing

@testable import LauncherCore

struct BoundedTreeTests {
  private func tree(_ files: [String: String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .resolvingSymlinksInPath()
    for (path, text) in files {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(text.utf8).write(to: url)
    }
    return root
  }

  private func remove(_ url: URL) {
    do { try FileManager.default.removeItem(at: url) } catch { print(error) }
  }

  @Test
  func `lists regular files sorted with their total size and treats absence as empty`() throws {
    let root = try tree(["b.txt": "22", "a/c.txt": "333"])
    defer { remove(root) }
    let summary = try BoundedTree.inventory(root)
    #expect(summary == BoundedTree.Summary(files: ["a/c.txt", "b.txt"], bytes: 5))
    #expect(try BoundedTree.inventory(root.appendingPathComponent("missing")).files.isEmpty)
  }

  @Test
  func `rejects links and enforces file, byte and depth limits`() throws {
    let root = try tree(["a.txt": "1", "b.txt": "2", "d1/d2/d3/c.txt": "3"])
    defer { remove(root) }
    #expect(throws: LauncherError.self) {
      try BoundedTree.inventory(root, limits: .init(files: 2))
    }
    #expect(throws: LauncherError.self) {
      try BoundedTree.inventory(root, limits: .init(bytes: 2))
    }
    #expect(throws: LauncherError.self) {
      try BoundedTree.inventory(root, limits: .init(depth: 2))
    }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("link"), withDestinationURL: root)
    #expect(throws: LauncherError.self) { try BoundedTree.inventory(root) }
    #expect(throws: LauncherError.self) {
      try BoundedTree.inventory(root.appendingPathComponent("link"))
    }
  }

  @Test
  func `copies a tree exactly and refuses an existing or nested destination`() throws {
    let root = try tree(["a.txt": "one", "d/b.txt": "two"])
    defer { remove(root) }
    let copy = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    defer { remove(copy) }
    let summary = try BoundedTree.copy(root, to: copy)
    #expect(try BoundedTree.inventory(copy) == summary)
    #expect(throws: LauncherError.self) { try BoundedTree.copy(root, to: copy) }
    #expect(throws: LauncherError.self) {
      try BoundedTree.copy(root, to: root.appendingPathComponent("inside"))
    }
  }

  @Test
  func `a failed copy leaves no destination behind`() throws {
    let root = try tree(["a.txt": "one"])
    defer { remove(root) }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("link"), withDestinationURL: root)
    let copy = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    #expect(throws: LauncherError.self) { try BoundedTree.copy(root, to: copy) }
    #expect(!FileManager.default.fileExists(atPath: copy.path))
  }
}

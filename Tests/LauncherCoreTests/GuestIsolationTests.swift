import Foundation
import Testing

@testable import LauncherCore

struct GuestIsolationTests {
  @Test func `removes host drive and user aliases while retaining game and saves`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let prefix = root.appendingPathComponent("Prefix")
    let files = FileManager.default
    defer { try? files.removeItem(at: root) }
    try files.createDirectory(
      at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
    try files.createDirectory(
      at: prefix.appendingPathComponent("drive_c/users/player"), withIntermediateDirectories: true)
    try files.createDirectory(
      at: root.appendingPathComponent("Saves"), withIntermediateDirectories: true)
    try files.createSymbolicLink(
      atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c"
    )
    try files.createSymbolicLink(
      atPath: prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
    try files.createSymbolicLink(
      atPath: prefix.appendingPathComponent("drive_c/users/player/Desktop").path,
      withDestinationPath: "/Users/friend/Desktop")
    try files.createSymbolicLink(
      atPath: prefix.appendingPathComponent("drive_c/NFSMWSaves").path,
      withDestinationPath: "../../Saves")
    try GuestIsolation.restrict(prefix: prefix, root: root)
    #expect(!files.fileExists(atPath: prefix.appendingPathComponent("dosdevices/z:").path))
    #expect(
      try prefix.appendingPathComponent("drive_c/users/player/Desktop").resourceValues(forKeys: [
        .isDirectoryKey
      ]).isDirectory == true)
    #expect(
      try files.destinationOfSymbolicLink(
        atPath: prefix.appendingPathComponent("drive_c/NFSMWSaves").path) == "../../Saves")
    try GuestIsolation.restrict(prefix: prefix, root: root)
  }

  @Test func `refuses unexpected real drive entries without deleting them`() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let prefix = root.appendingPathComponent("Prefix")
    let files = FileManager.default
    defer { try? files.removeItem(at: root) }
    try files.createDirectory(
      at: prefix.appendingPathComponent("dosdevices/z:"), withIntermediateDirectories: true)
    #expect(throws: LauncherError.self) { try GuestIsolation.restrict(prefix: prefix, root: root) }
    #expect(files.fileExists(atPath: prefix.appendingPathComponent("dosdevices/z:").path))
  }
  @Test(arguments: [false, true])
  func `recovers a prefix interrupted around publication`(published: Bool) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let prefix = root.appendingPathComponent("Prefix")
    let files = FileManager.default
    defer { try? files.removeItem(at: root) }
    let previous = prefix.appendingPathExtension("isolation-previous")
    try files.createDirectory(at: previous, withIntermediateDirectories: true)
    try Data("original".utf8).write(to: previous.appendingPathComponent("user.reg"))
    if published {
      try files.createDirectory(at: prefix, withIntermediateDirectories: false)
      try Data("restricted".utf8).write(to: prefix.appendingPathComponent("user.reg"))
    }
    try GuestIsolation.recover(prefix: prefix)
    #expect(
      try String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8)
        == (published ? "restricted" : "original"))
    #expect(!files.fileExists(atPath: previous.path))
  }

}

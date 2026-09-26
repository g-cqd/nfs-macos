import Foundation
import Testing

@testable import LauncherCore

struct ProcessCommandTests {
  @Test
  func `passes punctuation as data without shell expansion`() throws {
    let fixture = try InstallerFixture()
    defer { fixture.remove() }
    let log = fixture.root.appendingPathComponent("output")
    try Data().write(to: log)
    let handle = try FileHandle(forWritingTo: log)
    let literal = "spaces & $(touch should-not-exist) `literal` 'quoted'"
    let sut = ProcessCommand(
      executable: URL(fileURLWithPath: "/usr/bin/printf"),
      arguments: ["%s", literal], directory: fixture.root, environment: [:])
    let status = try sut.run(output: handle)
    try handle.close()
    #expect(status == 0)
    #expect(try String(contentsOf: log, encoding: .utf8) == literal)
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.root.appendingPathComponent("should-not-exist").path))
  }

  @Test
  func `preserves child failure status`() throws {
    let sut = ProcessCommand(
      executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
      directory: FileManager.default.temporaryDirectory, environment: [:])
    #expect(try sut.run(output: .nullDevice) == 1)
  }
}

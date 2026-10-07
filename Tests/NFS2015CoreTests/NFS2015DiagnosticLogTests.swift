import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

struct NFS2015DiagnosticLogTests {
  private func lines(_ router: inout NFS2015DiagnosticLog.Router, _ text: String)
    -> [(NFS2015DiagnosticLog.Route, String)]
  {
    router.feed(Data(text.utf8)).map { ($0.route, String(decoding: $0.line, as: UTF8.self)) }
  }

  // MARK: Channels

  @Test
  func `the diagnostic channels are a list Wine accepts and the app lets through`() {
    #expect(NFS2015DiagnosticLog.channels == "err+all,fixme-all,+seh")
    #expect(LaunchEnvironment.isDebugChannelList(NFS2015DiagnosticLog.channels))
    #expect(LaunchEnvironment.isDebugChannelList(LaunchEnvironment.silentDebugChannels))
  }

  @Test(arguments: [
    "", "+seh;rm -rf", "+SEH", "+seh +tid", "$(id)", "+seh\n", String(repeating: "a", count: 65),
  ])
  func `refuses a channel list that could carry anything else`(text: String) {
    #expect(!LaunchEnvironment.isDebugChannelList(text))
  }

  // MARK: Routing

  @Test
  func `sends Wine's trace lines to the debug files and the rest to the session log`() {
    var router = NFS2015DiagnosticLog.Router()
    let result = lines(
      &router,
      """
      0124:trace:seh:dispatch_exception code=c0000005 flags=0 addr=000000014341FB95
      wine: Unhandled page fault on read access to 0 at address 0 (thread 0124), starting debugger...
      0124:err:virtual:something went wrong
      info:  Setting display mode: 1920x1200@60

      """)
    #expect(result.map(\.0) == [.debug, .session, .session, .session])
    #expect(result[1].1.hasPrefix("wine: Unhandled"))
  }

  @Test
  func `waits for the end of a line and flushes the last one at the end of the stream`() {
    var router = NFS2015DiagnosticLog.Router()
    #expect(lines(&router, "0001:trace:se").isEmpty)
    #expect(lines(&router, "h:x\nabc").map(\.1) == ["0001:trace:seh:x"])
    let rest = router.finish()
    #expect(rest.map { String(decoding: $0.line, as: UTF8.self) } == ["abc"])
    #expect(router.finish().isEmpty)
  }

  @Test
  func `cuts a line that never ends and keeps reading after it`() {
    var router = NFS2015DiagnosticLog.Router()
    let long = String(repeating: "x", count: NFS2015DiagnosticLog.lineLimit * 3)
    let result = lines(&router, long + "\nafter\n")
    #expect(result.count == 2)
    #expect(result[0].1.count == NFS2015DiagnosticLog.lineLimit + " [line cut]".count)
    #expect(result[0].1.hasSuffix(" [line cut]") && result[1].1 == "after")
  }

  @Test
  func `a trace marker far into a line does not make it a debug line`() {
    var router = NFS2015DiagnosticLog.Router()
    let far = String(repeating: "x", count: 60) + ":trace:"
    #expect(lines(&router, far + "\n").map(\.0) == [.session])
  }

  // MARK: Rotation

  @Test
  func `rotates into numbered files and keeps only the newest ones`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    var segments = NFS2015DiagnosticLog.Segments(
      folder: scratch.root, stamp: "20261007T120000Z", segmentBytes: 100, segmentCount: 2)
    for number in 0..<10 {
      segments.append(Array("line \(number) \(String(repeating: "x", count: 20))".utf8))
    }
    segments.close()
    #expect(segments.failure == nil)
    let names = try FileManager.default.contentsOfDirectory(atPath: scratch.root.path).sorted()
    #expect(names.count == 2)
    #expect(segments.files.map(\.lastPathComponent) == names)
    #expect(names.allSatisfy { $0.hasPrefix("wine-debug-20261007T120000Z-") })
    let kept = try names.map { try scratch.text($0) }
    #expect(kept.allSatisfy { $0.utf8.count <= 100 })
    // The newest line survived, the oldest did not.
    #expect(kept.joined().contains("line 9 "))
    #expect(!kept.joined().contains("line 0 "))
  }

  @Test
  func `one line longer than a file does not make a file per append`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    var segments = NFS2015DiagnosticLog.Segments(
      folder: scratch.root, stamp: "20261007T120000Z", segmentBytes: 10, segmentCount: 4)
    segments.append(Array(String(repeating: "y", count: 50).utf8))
    segments.close()
    #expect(segments.files.count == 1)
  }

  @Test
  func `reports a folder it cannot write and then stops without crashing`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    chmod(scratch.root.path, 0o500)
    defer { chmod(scratch.root.path, 0o755) }
    var segments = NFS2015DiagnosticLog.Segments(folder: scratch.root, stamp: "20261007T120000Z")
    segments.append(Array("0001:trace:seh:x".utf8))
    segments.append(Array("0001:trace:seh:y".utf8))
    segments.close()
    #expect(segments.failure != nil && segments.files.isEmpty)
  }

  @Test
  func `deletes the oldest debug files of earlier launches until the rest fit`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    for name in ["wine-debug-A-001.log", "wine-debug-B-001.log", "wine-debug-C-001.log"] {
      try scratch.write(name, String(repeating: "z", count: 100))
    }
    try scratch.write("session-keep.log", String(repeating: "z", count: 1000))
    #expect(NFS2015DiagnosticLog.prune(in: scratch.root, limit: 250) == 1)
    let left = try FileManager.default.contentsOfDirectory(atPath: scratch.root.path).sorted()
    #expect(left == ["session-keep.log", "wine-debug-B-001.log", "wine-debug-C-001.log"])
    #expect(NFS2015DiagnosticLog.prune(in: scratch.root, limit: 250) == 0)
    #expect(NFS2015DiagnosticLog.prune(in: scratch.root, limit: 0) == 2)
  }

  @Test
  func `names files by a sortable UTC time`() {
    let stamp = NFS2015DiagnosticLog.stamp(Date(timeIntervalSince1970: 1_791_000_000))
    #expect(stamp == "20261003T040000Z")
    #expect(
      NFS2015DiagnosticLog.stamp(Date(timeIntervalSince1970: 1_791_000_001)) > stamp)
  }

  // MARK: The pipe

  @Test
  func `splits what Wine writes into debug files and the session log, and ends at the last close`()
    throws
  {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let main = try scratch.openLog("session.log")
    let capture = try NFS2015DiagnosticCapture(
      folder: scratch.url("Logs"), stamp: "20261007T120000Z", main: main)
    try capture.output.write(
      contentsOf: Data(
        "0001:trace:seh:dispatch_exception code=c0000005\ninfo:  hello\n0001:trace:seh:  rax=1\n"
          .utf8))
    #expect(capture.finish(timeout: 10))
    #expect(capture.failure == nil)
    let debug = try #require(capture.files.first)
    let kept = String(decoding: try Data(contentsOf: debug), as: UTF8.self)
    #expect(
      kept.contains("dispatch_exception") && kept.contains("rax=1") && !kept.contains("hello"))
    #expect(try scratch.text("session.log") == "info:  hello\n")
  }

  @Test
  func `keeps draining the pipe after it cannot write a debug file, so Wine is never blocked`()
    throws
  {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let folder = scratch.url("Logs")
    let main = try scratch.openLog("session.log")
    let capture = try NFS2015DiagnosticCapture(
      folder: folder, stamp: "20261007T120000Z", main: main)
    chmod(folder.path, 0o500)
    defer { chmod(folder.path, 0o755) }
    // More than a pipe buffer holds: this write would block forever if nobody read it.
    let burst = Data(
      String(repeating: "0001:trace:seh:" + String(repeating: "x", count: 60) + "\n", count: 5000)
        .utf8)
    try capture.output.write(contentsOf: burst)
    #expect(capture.finish(timeout: 10))
    #expect(capture.failure != nil)
  }

  @Test
  func
    `closes the read end and reports it when reading fails, so Wine's writes fail and never block`()
    throws
  {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let pipe = Pipe()
    try pipe.fileHandleForReading.close()
    let capture = try NFS2015DiagnosticCapture(
      folder: scratch.url("Logs"), stamp: "20261007T120000Z", main: try scratch.openLog("s.log"),
      pipe: pipe)
    #expect(capture.finish(timeout: 10))
    #expect(capture.failure != nil)
  }

  @Test
  func `bounds a long burst of debug lines to the newest files`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    var segments = NFS2015DiagnosticLog.Segments(
      folder: scratch.root, stamp: "20261007T120000Z", segmentBytes: 1_000, segmentCount: 3)
    for number in 0..<5_000 { segments.append(Array("0001:trace:seh:line \(number)".utf8)) }
    segments.close()
    let total = try segments.files.reduce(0) {
      $0 + (try Data(contentsOf: $1)).count
    }
    #expect(total <= 3_000 && segments.files.count == 3)
  }
}

extension Scratch {
  /// A file opened for writing, as the starter opens the session log.
  func openLog(_ name: String) throws -> FileHandle {
    let target = url(name)
    try Data().write(to: target)
    return try FileHandle(forWritingTo: target)
  }
}

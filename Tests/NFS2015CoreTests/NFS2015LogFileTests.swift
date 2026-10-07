import Foundation
import Testing

@testable import NFS2015Core

struct NFS2015LogFileTests {
  @Test
  func `finds the file a handle writes to`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let handle = try scratch.openLog("session.log")
    defer { try? handle.close() }
    let found = try #require(NFS2015LogFile.path(of: handle))
    #expect(
      found.resolvingSymlinksInPath().path
        == scratch.url("session.log").resolvingSymlinksInPath().path)
  }

  @Test
  func `finds nothing for a pipe`() {
    let pipe = Pipe()
    defer {
      try? pipe.fileHandleForReading.close()
      try? pipe.fileHandleForWriting.close()
    }
    #expect(NFS2015LogFile.path(of: pipe.fileHandleForWriting) == nil)
  }

  @Test
  func `reads what a file gained since an offset`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let url = try scratch.write("a.log", "one\ntwo\n")
    let first = try #require(NFS2015LogFile.read(url, from: 0))
    #expect(first.text == "one\ntwo\n" && first.next == 8)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("three\n".utf8))
    try handle.close()
    let second = try #require(NFS2015LogFile.read(url, from: first.next))
    #expect(second.text == "three\n" && second.next == 14)
    let none = try #require(NFS2015LogFile.read(url, from: second.next))
    #expect(none.text.isEmpty && none.next == 14)
  }

  @Test
  func `starts again from the top when the file became shorter`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let url = try scratch.write("a.log", "short\n")
    let read = try #require(NFS2015LogFile.read(url, from: 1_000))
    #expect(read.text == "short\n" && read.next == 6)
  }

  @Test
  func `has nothing for a file that does not exist`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    #expect(NFS2015LogFile.read(scratch.url("none"), from: 0) == nil)
    #expect(NFS2015LogFile.tail(scratch.url("none"), bytes: 10) == nil)
  }

  @Test
  func `reads at most the read limit at a time`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let url = try scratch.write(
      "big.log", String(repeating: "a", count: NFS2015LogFile.readLimit + 100))
    let first = try #require(NFS2015LogFile.read(url, from: 0))
    #expect(first.text.utf8.count == NFS2015LogFile.readLimit)
    let rest = try #require(NFS2015LogFile.read(url, from: first.next))
    #expect(rest.text.utf8.count == 100)
  }

  @Test
  func `reads the end of a file`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let url = try scratch.write("t.log", "0123456789")
    #expect(NFS2015LogFile.tail(url, bytes: 4) == "6789")
    #expect(NFS2015LogFile.tail(url, bytes: 100) == "0123456789")
  }
}

struct NFS2015SnapshotCompatibilityTests {
  @Test
  func `a state file an older version wrote still reads, as the defaults and no crash`() throws {
    let old = #"{"hasOptionsFile":false,"settings":{"values":{}}}"#
    let snapshot = try JSONDecoder().decode(NFS2015Snapshot.self, from: Data(old.utf8))
    #expect(snapshot.diagnostics == nil && snapshot.crashReport == nil)
  }

  @Test
  func `carries the diagnostics state and the crash report through the state file`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let snapshot = NFS2015Snapshot(
      diagnostics: NFS2015DiagnosticsState(
        preference: NFS2015DiagnosticsPreference(diagnosticLoggingNextLaunch: true),
        outcome: .saved, displayNote: "RetinaMode is turned off."),
      crashReport: NFS2015CrashNotice(path: "/x/crash-report-1.txt", headline: "1 fault"))
    try snapshot.write(to: scratch.url("state.json"))
    #expect(try NFS2015Snapshot.read(from: scratch.url("state.json")) == snapshot)
  }
}

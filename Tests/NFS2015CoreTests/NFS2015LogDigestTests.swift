import Foundation
import Testing

@testable import NFS2015Core

struct NFS2015LogDigestTests {
  @Test
  func `counts the game launches, the faults, the display modes and the server crashes`() {
    let digest = NFS2015LogDigest(log: CrashFixtures.log)
    #expect(digest.launches == 2)
    #expect(digest.faults.count == 3)
    #expect(digest.serverCrashes == 1)
    #expect(digest.displayModes.map(\.mode) == ["3360x2100@60", "1920x1200@60"])
    #expect(digest.displayModes.map(\.count) == [2, 2])
  }

  @Test
  func `reading in small pieces gives the same answer as reading all at once`() {
    let whole = NFS2015LogDigest(log: CrashFixtures.log)
    for size in [1, 7, 64, 1000] {
      var pieces = NFS2015LogDigest()
      var text = Substring(CrashFixtures.log)
      while !text.isEmpty {
        pieces.feed(String(text.prefix(size)))
        text = text.dropFirst(size)
      }
      pieces.finish()
      #expect(pieces == whole, "piece size \(size)")
    }
  }

  @Test
  func `a final line without a line feed is read at the end`() {
    var digest = NFS2015LogDigest()
    digest.feed("compatdb: NFS16.exe [x86_64]")
    #expect(digest.launches == 0)
    digest.finish()
    #expect(digest.launches == 1)
    digest.finish()
    #expect(digest.launches == 1)
  }

  @Test
  func `keeps only diagnostic lines, and none that carry a credential`() {
    let digest = NFS2015LogDigest(log: CrashFixtures.log)
    let kept = (digest.context + digest.trace).joined(separator: "\n")
    for secret in CrashFixtures.secrets { #expect(!kept.contains(secret), "\(secret)") }
    #expect(!kept.contains("FIDO") && !kept.contains("cookie_manager"))
    #expect(!kept.contains("compatdb"))
    #expect(kept.contains("Setting display mode: 3360x2100@60"))
  }

  @Test
  func `stays bounded however long the log runs`() {
    var digest = NFS2015LogDigest()
    for number in 0..<5_000 {
      digest.feed("info:  line \(number)\n0001:trace:seh:record \(number)\n")
      digest.feed("info:  Setting display mode: \(1000 + number)x700@60\n")
      digest.feed(NFS2015FaultAnalysisTests.nullCall + "\n")
    }
    #expect(digest.context.count == NFS2015LogDigest.contextLimit)
    #expect(digest.trace.count == NFS2015LogDigest.traceLimit)
    #expect(digest.faults.count == NFS2015LogDigest.faultLimit)
    #expect(digest.displayModes.count == NFS2015LogDigest.modeLimit)
    // The newest lines are the ones kept.
    #expect(digest.trace.last == "0001:trace:seh:record 4999")
  }

  @Test
  func `a single enormous line does not grow without bound`() {
    var digest = NFS2015LogDigest()
    for _ in 0..<1_000 { digest.feed(String(repeating: "x", count: 1_000)) }
    digest.feed("\ncompatdb: NFS16.exe [x86_64]\n")
    #expect(digest.launches == 1)
  }

  @Test
  func `takes the exception trace from the end of a debug file`() {
    var digest = NFS2015LogDigest()
    let file = (0..<200).map { "0001:trace:seh:record \($0)" }.joined(separator: "\n") + "\nnoise\n"
    digest.setTrace(fromText: file)
    #expect(digest.trace.count == NFS2015LogDigest.traceLimit)
    #expect(digest.trace.last == "0001:trace:seh:record 199")
  }

  @Test
  func `reads a display mode only from its line`() {
    #expect(
      NFS2015LogDigest.displayMode(in: "info:  Setting display mode: 1920x1200@60")
        == "1920x1200@60")
    #expect(NFS2015LogDigest.displayMode(in: "info:  Setting display mode: abc") == nil)
    #expect(NFS2015LogDigest.displayMode(in: "info:  nothing") == nil)
  }
}

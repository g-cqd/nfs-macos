import Foundation
import Testing

@testable import NFS2015Core

struct NFS2015RedactionTests {
  @Test(
    arguments: [
      "info:  request with access_token=abc", "warn:  Authorization: Bearer abc",
      "info:  authCode=ZZZ", "info:  Set-Cookie: a=b", "info:  sessionId 12", "info:  password",
      "info:  nucleus id", "info:  login failed for someone", "info:  user someone@example.com",
      "info:  JWT eyJhbGciOiJIUzI1NiJ9", "info:  client_secret", "info:  your email",
      "info:  persona 123", "info:  oauth flow", "info:  account 1",
    ])
  func `drops a line that mentions a credential or an identity`(line: String) {
    #expect(NFS2015Redaction.carriesMarker(line))
    #expect(NFS2015Redaction.scrub(line) == nil)
  }

  @Test
  func `keeps the lines a crash report is made of`() {
    for line in [
      "info:  Setting display mode: 1920x1200@60", "info:  Setting display mode: 1920x1200@59.94",
      "wine: Unhandled page fault on read access to 0 at address 0 (thread 0001), starting debugger...",
      "0001:trace:seh:dispatch_exception code=c0000005 flags=0 addr=000000014341FB95",
      "[rosettax87] x87 cache: block hash=0x74573adad0511748 translated again (ask=14)",
    ] {
      #expect(NFS2015Redaction.scrub(line) != nil, "\(line)")
    }
  }

  @Test
  func `a bare at sign is not an address, a name at a host is`() {
    #expect(!NFS2015Redaction.containsAddress("1920x1200@60"))
    #expect(!NFS2015Redaction.containsAddress("1920x1200@59.94"))
    #expect(!NFS2015Redaction.containsAddress("a @ b"))
    #expect(NFS2015Redaction.containsAddress("mail someone@example.com now"))
    #expect(NFS2015Redaction.containsAddress("x@y.z"))
    #expect(!NFS2015Redaction.containsAddress("x@y."))
  }

  @Test
  func `admits only the shapes of line a crash report uses`() {
    for line in [
      "info:  a", "warn:  a", "wine: a", "err:x", "fixme:x", "[rosettax87] x",
      "0001:trace:seh:x", "0001:err:virtual:x",
    ] { #expect(NFS2015Redaction.isDiagnostic(line), "\(line)") }
    for line in [
      "[1007/211844.212:ERROR:device_event_log_impl.cc(215)] FIDO", "compatdb: NFS16.exe [x86_64]",
      "EA app 13.796", "", "information",
    ] { #expect(!NFS2015Redaction.isDiagnostic(line), "\(line)") }
  }

  @Test
  func `replaces the home folder's name`() {
    #expect(
      NFS2015Redaction.maskHome("opened /Users/someone/Library/x and /Users/other/y")
        == "opened /Users/<user>/Library/x and /Users/<user>/y")
    #expect(NFS2015Redaction.maskHome("path /Users/ and more") == "path /Users/ and more")
    #expect(NFS2015Redaction.maskHome("no path") == "no path")
    #expect(NFS2015Redaction.maskHome("\"/Users/someone\"") == "\"/Users/<user>\"")
  }

  @Test
  func `masks long machine-looking strings but not words, numbers or short hashes`() {
    let key = "A1b2C3d4E5f6G7h8I9j0K1l2M3n4"
    #expect(NFS2015Redaction.maskLongStrings("key \(key) end") == "key <masked> end")
    #expect(
      NFS2015Redaction.maskLongStrings(String(repeating: "a", count: 40))
        == String(repeating: "a", count: 40))
    #expect(
      NFS2015Redaction.maskLongStrings(String(repeating: "7", count: 40))
        == String(repeating: "7", count: 40))
    #expect(
      NFS2015Redaction.maskLongStrings("block hash=0x74573adad0511748 ok")
        == "block hash=0x74573adad0511748 ok")
    #expect(NFS2015Redaction.maskLongStrings("short A1b2C3") == "short A1b2C3")
  }

  @Test
  func `scrubbing a line applies the drop, the home mask and the long-string mask`() {
    #expect(
      NFS2015Redaction.scrub("info:  /Users/someone/x A1b2C3d4E5f6G7h8I9j0K1l2M3n4")
        == "info:  /Users/<user>/x <masked>")
    #expect(NFS2015Redaction.scrub(String(repeating: "i", count: 1000))?.count == 400)
  }

  @Test
  func `a report keeps its hashes and loses any line with a credential word`() {
    let hash = String(repeating: "ab12", count: 16)
    let text = NFS2015Redaction.scrubReport(
      "sha256 \(hash)\nthe token is here\nmode 1920x1200@60\n/Users/someone/Logs")
    #expect(
      text
        == "sha256 \(hash)\n<line removed: it mentions a credential-related word>\nmode 1920x1200@60\n/Users/<user>/Logs"
    )
  }
}

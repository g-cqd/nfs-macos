import Foundation
import Testing

@testable import NFS2015Core

/// The fault lines below are the ones Wine printed in the logs of two Macs on 2026-10-07; they
/// hold only addresses and a thread number.
struct NFS2015FaultAnalysisTests {
  static let writeGarbage =
    "wine: Unhandled page fault on write access to 85BC35850173FF31 at address 0000000001B30159 (thread 0a94), starting debugger..."
  static let textPointer =
    "wine: Unhandled page fault on read access to 73656C6369686556 at address 000000014341FB95 (thread 0fb0), starting debugger..."
  static let executeHeap =
    "wine: Unhandled page fault on execute access to 0000000023B5A8B0 at address 0000000023B5A8B0 (thread 02cc), starting debugger..."
  static let wideText =
    "wine: Unhandled page fault on read access to 0056002800000007 at address 00000001434476FA (thread 0768), starting debugger..."
  static let nullRead =
    "wine: Unhandled page fault on read access to 0000000000000000 at address 00000001447D1383 (thread 0688), starting debugger..."
  static let nullCall =
    "wine: Unhandled page fault on read access to 0000000000000000 at address 0000000000000000 (thread 057c), starting debugger..."

  private func finding(_ text: String) throws -> NFS2015FaultFinding {
    NFS2015FaultFinding(line: try #require(NFS2015FaultLine.parse(text)))
  }

  @Test
  func `reads a page fault line into its access, value, address and thread`() throws {
    let line = try #require(NFS2015FaultLine.parse(Self.textPointer))
    #expect(line.kind == .pageFault(access: "read", value: 0x7365_6C63_6968_6556))
    #expect(line.address == 0x1_4341_FB95 && line.thread == "0fb0")
    #expect(line.text == Self.textPointer)
  }

  @Test
  func `reads an unhandled exception line`() throws {
    let line = try #require(
      NFS2015FaultLine.parse(
        "wine: Unhandled exception 0xc0000005 at address 00000001400000AA (thread 0123), starting debugger..."
      ))
    #expect(line.kind == .exception(code: 0xC000_0005) && line.address == 0x1_4000_00AA)
  }

  @Test(
    arguments: [
      "", "wine: ", "wine: Unhandled page fault on read access to ZZ at address 0 (thread 0001)",
      "wine: Unhandled page fault on read access to 0 at address 0",
      "wine: Unhandled page fault on peek access to 0 at address 0 (thread 0001)",
      "wine: Unhandled page fault on read access to 00000000000000000 at address 0 (thread 0001)",
      "info: Unhandled page fault on read access to 0 at address 0 (thread 0001)",
      "wine: Unhandled exception notacode at address 0 (thread 0001)",
      "wine: Unhandled page fault on read access to 0 at address 0 (thread )",
      "wine: Unhandled page fault on read access to 0 at address 0 (thread 123456789)",
    ])
  func `ignores a line that is not a well-formed fault`(text: String) {
    #expect(NFS2015FaultLine.parse(text) == nil)
  }

  @Test
  func `finds the fault lines in a log and ignores everything else`() {
    let log = "info:  x\n\(Self.nullCall)\n[1007/21:ERROR:foo] bar\n\(Self.nullRead)\n"
    #expect(NFS2015FaultLine.lines(in: log).map(\.thread) == ["057c", "0688"])
  }

  @Test
  func `a call through a null function pointer`() throws {
    let found = try finding(Self.nullCall)
    #expect(found.patterns == ["call or jump through a null function pointer"])
    #expect(found.rva == nil && found.location.contains("outside nfs16"))
  }

  @Test
  func `a null read inside the game image names the module and offset`() throws {
    let found = try finding(Self.nullRead)
    #expect(found.location == "nfs16+0x47D1383" && found.rva == 0x47D_1383)
    #expect(found.patterns == ["null pointer read"])
  }

  @Test
  func `a pointer that spells ASCII text`() throws {
    let found = try finding(Self.textPointer)
    #expect(found.location == "nfs16+0x341FB95")
    #expect(found.patterns.contains { $0.contains("ASCII text \"Vehicles\"") })
  }

  @Test
  func `a pointer that may be wide text, and is not an address`() throws {
    let found = try finding(Self.wideText)
    #expect(found.patterns.contains { $0.contains("UTF-16") })
    #expect(found.patterns.contains { $0.contains("non-canonical") })
  }

  @Test
  func `a write through a value that is not an address, from outside the game image`() throws {
    let found = try finding(Self.writeGarbage)
    #expect(found.patterns.contains { $0.contains("non-canonical") })
    #expect(found.patterns.contains { $0.contains("outside nfs16") })
    #expect(found.location.hasPrefix("0x1B30159, outside nfs16"))
  }

  @Test
  func `an execute fault below the image is heap or data, not game code`() throws {
    let found = try finding(Self.executeHeap)
    #expect(
      found.patterns == [
        "execute fault outside the image: the target is heap or data, not game code"
      ])
  }

  @Test
  func `reports a jump to a small number and to a non-canonical address`() throws {
    let small = try finding(
      "wine: Unhandled page fault on execute access to 0000000000000008 at address 0000000000000008 (thread 0001), starting debugger..."
    )
    #expect(small.patterns.first?.contains("small number") == true)
    let wild = try finding(
      "wine: Unhandled page fault on execute access to FFFF000000000010 at address FFFF000000000010 (thread 0001), starting debugger..."
    )
    #expect(wild.patterns.first?.contains("non-canonical") == true)
  }

  @Test
  func `a near-null access is a field of a null object`() throws {
    let found = try finding(
      "wine: Unhandled page fault on write access to 0000000000000028 at address 0000000140001000 (thread 0001), starting debugger..."
    )
    #expect(found.patterns.first?.contains("near-null write at 0x28") == true)
  }

  @Test
  func `maps addresses to the image at its exact edges`() {
    func rva(_ address: UInt64) -> UInt64? {
      let line = NFS2015FaultLine(
        kind: .pageFault(access: "read", value: 0), address: address, thread: "1", text: "")
      return NFS2015FaultFinding(line: line).rva
    }
    #expect(rva(0x1_3FFF_FFFF) == nil)
    #expect(rva(0x1_4000_0000) == 0)
    #expect(rva(0x1_488F_1FFF) == 0x88F_1FFF)
    #expect(rva(0x1_488F_2000) == nil)
    let custom = NFS2015FaultFinding(
      line: NFS2015FaultLine(
        kind: .pageFault(access: "read", value: 0), address: 0x1_4000_1000, thread: "1", text: ""),
      imageSize: 0x800)
    #expect(custom.rva == nil)
  }

  @Test(arguments: [
    (UInt64(0x2020_2020_2020_2020), "        "), (0x7365_6C63_6968_6556, "Vehicles"),
  ])
  func `reads eight printable bytes as text`(value: UInt64, text: String) {
    #expect(NFS2015FaultFinding.asciiText(value) == text)
  }

  @Test(arguments: [UInt64(0), 0x0073_656C_6369_6856, 0x7365_6C63_6968_6501, 0x7F65_6C63_6968_6556])
  func `does not read other values as text`(value: UInt64) {
    #expect(NFS2015FaultFinding.asciiText(value) == nil)
  }

  @Test
  func `recognises wide text only with two printable lanes and byte-sized others`() {
    #expect(NFS2015FaultFinding.looksLikeUTF16(0x0056_0028_0000_0007))
    #expect(!NFS2015FaultFinding.looksLikeUTF16(0x0000_0000_0000_0028))
    #expect(!NFS2015FaultFinding.looksLikeUTF16(0x0056_0028_0100_0007))
    #expect(!NFS2015FaultFinding.looksLikeUTF16(0x7FF8_1234_5678_9ABC))
  }
}

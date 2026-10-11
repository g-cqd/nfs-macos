import Foundation

/// Builds synthetic PE32/PE32+ images with import and delay-import tables for the PE scanner tests.
/// They contain no game code or data.
///
/// Layout (fixed so tests can patch bytes): DOS header, `e_lfanew` = 0x40, COFF at 0x44, optional header at 0x58
/// (224 bytes PE32, 240 bytes PE32+), two section headers, `.rdata` at file offset 0x200 / RVA 0x1000, `.text`
/// after it. `.rdata` holds the import descriptors, then the delay descriptors, then the NUL-terminated names.
enum PEFixture {
  static let peOffset = 0x40
  static let coffOffset = peOffset + 4
  static let rdataFileOffset = 0x200
  static let rdataRVA: UInt32 = 0x1000
  static let imageBase: UInt32 = 0x40_0000
  static let timestamp: UInt32 = 0x1234_5678

  static func make(
    machine: UInt16, pe32Plus: Bool, subsystem: UInt16, dll: Bool,
    imports: [String], delayImports: [String], delayUsesVA: Bool
  ) -> [UInt8] {
    let optionalSize = pe32Plus ? 240 : 224
    let optionalOffset = peOffset + 24

    // .rdata content: import table, delay table, names.
    let importTableSize = imports.isEmpty ? 0 : (imports.count + 1) * 20
    let delayTableOffset = (importTableSize + 15) & ~15
    let delayTableSize = delayImports.isEmpty ? 0 : (delayImports.count + 1) * 32
    var nameOffset = delayTableOffset + delayTableSize
    var rdata = [UInt8](repeating: 0, count: nameOffset)
    func putName(_ name: String) -> UInt32 {
      let rva = rdataRVA + UInt32(nameOffset)
      rdata.append(contentsOf: Array(name.utf8) + [0])
      nameOffset = rdata.count
      return rva
    }
    for (i, name) in imports.enumerated() {
      put32(&rdata, i * 20 + 12, putName(name))
    }
    for (i, name) in delayImports.enumerated() {
      let rva = putName(name)
      let base = delayTableOffset + i * 32
      put32(&rdata, base, delayUsesVA ? 0 : 1)
      put32(&rdata, base + 4, delayUsesVA ? rva + imageBase : rva)
    }
    let rawSize = max(0x200, (rdata.count + 0x1FF) & ~0x1FF)
    rdata.append(contentsOf: [UInt8](repeating: 0, count: rawSize - rdata.count))
    let textRVA = (rdataRVA + UInt32(rawSize) + 0xFFF) & ~0xFFF
    let textFileOffset = rdataFileOffset + rawSize

    var file = [UInt8](repeating: 0, count: rdataFileOffset)
    file[0] = 0x4D
    file[1] = 0x5A
    put32(&file, 0x3C, UInt32(peOffset))
    file[peOffset...peOffset + 3] = [0x50, 0x45, 0, 0]

    let coff = peOffset + 4
    put16(&file, coff, machine)
    put16(&file, coff + 2, 2)
    put32(&file, coff + 4, timestamp)
    put16(&file, coff + 16, UInt16(optionalSize))
    put16(&file, coff + 18, 0x0102 | (dll ? 0x2000 : 0))

    put16(&file, optionalOffset, pe32Plus ? 0x20B : 0x10B)
    let directories: Int
    if pe32Plus {
      put32(&file, optionalOffset + 24, imageBase)  // u64 ImageBase, high half stays 0
      put32(&file, optionalOffset + 108, 16)
      directories = optionalOffset + 112
    } else {
      put32(&file, optionalOffset + 28, imageBase)
      put32(&file, optionalOffset + 92, 16)
      directories = optionalOffset + 96
    }
    put16(&file, optionalOffset + 68, subsystem)
    if !imports.isEmpty {
      put32(&file, directories + 8, rdataRVA)
      put32(&file, directories + 12, UInt32(importTableSize))
    }
    if !delayImports.isEmpty {
      put32(&file, directories + 13 * 8, rdataRVA + UInt32(delayTableOffset))
      put32(&file, directories + 13 * 8 + 4, UInt32(delayTableSize))
    }

    let sections = optionalOffset + optionalSize
    putSection(&file, sections, ".rdata", virtualSize: UInt32(rdata.count), rva: rdataRVA,
               rawSize: UInt32(rawSize), rawOffset: UInt32(rdataFileOffset))
    putSection(&file, sections + 40, ".text", virtualSize: 0x200, rva: textRVA,
               rawSize: 0x200, rawOffset: UInt32(textFileOffset))

    file.append(contentsOf: rdata)
    file.append(contentsOf: [UInt8](repeating: 0x90, count: 0x200))
    return file
  }

  /// File offset of the first occurrence of `needle` (an ASCII name), for patching.
  static func offset(of needle: String, in file: [UInt8]) -> Int? {
    let pattern = Array(needle.utf8)
    guard !pattern.isEmpty, file.count >= pattern.count else { return nil }
    for start in 0...(file.count - pattern.count) where Array(file[start..<start + pattern.count]) == pattern {
      return start
    }
    return nil
  }

  static func put16(_ buffer: inout [UInt8], _ at: Int, _ value: UInt16) {
    buffer[at] = UInt8(value & 0xFF)
    buffer[at + 1] = UInt8(value >> 8)
  }

  static func put32(_ buffer: inout [UInt8], _ at: Int, _ value: UInt32) {
    for i in 0..<4 { buffer[at + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
  }

  private static func putSection(
    _ file: inout [UInt8], _ at: Int, _ name: String,
    virtualSize: UInt32, rva: UInt32, rawSize: UInt32, rawOffset: UInt32
  ) {
    for (i, byte) in name.utf8.prefix(8).enumerated() { file[at + i] = byte }
    put32(&file, at + 8, virtualSize)
    put32(&file, at + 12, rva)
    put32(&file, at + 16, rawSize)
    put32(&file, at + 20, rawOffset)
  }
}

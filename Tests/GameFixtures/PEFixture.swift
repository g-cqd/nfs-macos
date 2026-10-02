import Foundation

/// Builds tiny synthetic PE32 images for tests. They contain no game code or data.
package enum PEFixture {
  package struct Options {
    package var machine: UInt16 = 0x14C
    package var dynamicLibrary = false
    package var fileVersion: (UInt16, UInt16, UInt16, UInt16)? = (1, 0, 3, 0)
    package var strings: [(String, String)] = []
    package var pe32Plus = false
    package init() {}
  }

  package static func make(_ options: Options = Options()) -> [UInt8] {
    let optionalSize = options.pe32Plus ? 240 : 224
    let headers = 0x80 + 24 + optionalSize + 40
    let rawOffset = (headers + 0x1FF) & ~0x1FF
    let resource = options.fileVersion == nil ? [] : resourceSection(options)
    var image = [UInt8](repeating: 0, count: rawOffset + resource.count)
    func put16(_ offset: Int, _ value: UInt16) {
      image[offset] = UInt8(value & 0xFF)
      image[offset + 1] = UInt8(value >> 8)
    }
    func put32(_ offset: Int, _ value: UInt32) {
      for index in 0..<4 { image[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xFF) }
    }
    image[0] = 0x4D
    image[1] = 0x5A
    put32(0x3C, 0x80)
    image[0x80] = 0x50
    image[0x81] = 0x45
    put16(0x84, options.machine)
    put16(0x86, 1)
    put16(0x94, UInt16(optionalSize))
    put16(0x96, options.dynamicLibrary ? 0x2102 : 0x0102)
    let optional = 0x80 + 24
    put16(optional, options.pe32Plus ? 0x20B : 0x10B)
    let directories = optional + (options.pe32Plus ? 112 : 96)
    put32(directories - 4, 16)
    if !resource.isEmpty {
      put32(directories + 16, 0x1000)
      put32(directories + 20, UInt32(resource.count))
    }
    let section = optional + optionalSize
    for (index, byte) in Array(".rsrc".utf8).enumerated() { image[section + index] = byte }
    put32(section + 8, UInt32(resource.count))
    put32(section + 12, 0x1000)
    put32(section + 16, UInt32(resource.count))
    put32(section + 20, UInt32(rawOffset))
    image.replaceSubrange(rawOffset..<(rawOffset + resource.count), with: resource)
    return image
  }

  private static func resourceSection(_ options: Options) -> [UInt8] {
    var blob: [UInt8] = []
    func word(_ value: UInt16) { blob += [UInt8(value & 0xFF), UInt8(value >> 8)] }
    func dword(_ value: UInt32) {
      blob += (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) }
    }
    func pad() { while blob.count % 4 != 0 { blob.append(0) } }
    func utf16(_ text: String) {
      for unit in text.utf16 { word(unit) }
      word(0)
    }
    word(0x1F0)
    word(52)
    word(0)
    utf16("VS_VERSION_INFO")
    pad()
    let version = options.fileVersion ?? (0, 0, 0, 0)
    dword(0xFEEF_04BD)
    dword(0x0001_0000)
    dword(UInt32(version.0) << 16 | UInt32(version.1))
    dword(UInt32(version.2) << 16 | UInt32(version.3))
    dword(UInt32(version.0) << 16 | UInt32(version.1))
    dword(UInt32(version.2) << 16 | UInt32(version.3))
    for _ in 0..<6 { dword(0) }
    pad()
    for (key, value) in options.strings {
      word(0x40)
      word(UInt16(value.utf16.count + 1))
      word(1)
      utf16(key)
      pad()
      utf16(value)
      pad()
    }
    var section: [UInt8] = []
    func put16(_ value: UInt16) { section += [UInt8(value & 0xFF), UInt8(value >> 8)] }
    func put32(_ value: UInt32) {
      section += (0..<4).map { UInt8((value >> (8 * UInt32($0))) & 0xFF) }
    }
    // Type directory (RT_VERSION), name directory, language directory, then one data entry.
    func directory(entryID: UInt32, target: UInt32) {
      for _ in 0..<3 { put32(0) }
      put16(0)
      put16(1)
      put32(entryID)
      put32(target)
    }
    directory(entryID: 16, target: 0x8000_0000 | 0x18)
    directory(entryID: 1, target: 0x8000_0000 | 0x30)
    directory(entryID: 0x409, target: 0x48)
    for value in [UInt32(0x1000 + 0x58), UInt32(blob.count), 0, 0] { put32(value) }
    return section + blob
  }
}

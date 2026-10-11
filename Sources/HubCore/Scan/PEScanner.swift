import Foundation
import Darwin

/// Facts extracted from a Windows PE (Portable Executable) header.
package struct PEFacts: Codable, Equatable, Sendable {
  /// Machine type: "i386", "x86_64", "arm64", or "0x..." for unknown values.
  package var machine: String
  /// Whether the optional header is PE32+ (64-bit) rather than PE32 (32-bit).
  package var pe32Plus: Bool
  /// Whether the file is a DLL rather than an executable.
  package var isDLL: Bool
  /// Subsystem: "gui", "console", or "other:<n>" for unknown values.
  package var subsystem: String
  /// Section names in order, with non-ASCII bytes replaced by `?`.
  package var sections: [String]
  /// Import DLL names: lowercased, deduplicated, sorted.
  package var imports: [String]
  /// Delay-import DLL names: lowercased, deduplicated, sorted.
  package var delayImports: [String]
  /// Timestamp from COFF header (whole seconds since 1970).
  package var timestamp: UInt32

  package init(
    machine: String, pe32Plus: Bool, isDLL: Bool, subsystem: String,
    sections: [String], imports: [String], delayImports: [String], timestamp: UInt32
  ) {
    self.machine = machine
    self.pe32Plus = pe32Plus
    self.isDLL = isDLL
    self.subsystem = subsystem
    self.sections = sections
    self.imports = imports
    self.delayImports = delayImports
    self.timestamp = timestamp
  }
}

/// PE (Portable Executable) parser for untrusted Windows binaries.
///
/// Parses PE32 and PE32+ headers, extracting machine type, sections, imports, and delay imports.
/// All offsets are bounds-checked; malformed files throw `HubError.invalid`.
package enum PEScanner {
  private static let sizeLimit = 512 << 20 // 512 MiB
  private static let maxDescriptors = 1024
  private static let maxNameBytes = 256
  private static let maxSections = 96
  private static let maxSubdirectories = 256

  /// Parses a PE file from raw bytes.
  ///
  /// - Throws: `HubError.invalid` if the file is malformed or cannot be parsed.
  package static func parse(_ bytes: [UInt8]) throws(HubError) -> PEFacts {
    // Check MZ header and get e_lfanew
    guard bytes.count >= 64, bytes[0] == 0x4D, bytes[1] == 0x5A else {
      throw .invalid("PE: missing MZ header")
    }

    guard let elfanew = le32(bytes, 0x3C) else {
      throw .invalid("PE: cannot read e_lfanew")
    }
    let elfanewInt = Int(elfanew)
    guard elfanewInt >= 0x40 && elfanewInt <= min(bytes.count - 24, 0x1000_0000) else {
      throw .invalid("PE: e_lfanew out of range")
    }

    // Check PE signature
    guard elfanewInt + 4 <= bytes.count,
          bytes[elfanewInt] == 0x50, bytes[elfanewInt + 1] == 0x45,
          bytes[elfanewInt + 2] == 0, bytes[elfanewInt + 3] == 0 else {
      throw .invalid("PE: missing PE signature")
    }

    // Read COFF header (starts at elfanewInt + 4)
    let coffOffset = elfanewInt + 4
    guard coffOffset + 20 <= bytes.count else {
      throw .invalid("PE: COFF header truncated")
    }

    guard let machineCode = le16(bytes, coffOffset) else {
      throw .invalid("PE: cannot read machine")
    }
    let machine = machineString(machineCode)

    guard let numSections = le16(bytes, coffOffset + 2) else {
      throw .invalid("PE: cannot read numberOfSections")
    }
    let numSectionsInt = Int(numSections)
    guard numSectionsInt >= 1 && numSectionsInt <= maxSections else {
      throw .invalid("PE: numberOfSections out of range")
    }

    guard let timestamp = le32(bytes, coffOffset + 4) else {
      throw .invalid("PE: cannot read timeDateStamp")
    }

    guard let optionalHeaderSize = le16(bytes, coffOffset + 16) else {
      throw .invalid("PE: cannot read sizeOfOptionalHeader")
    }
    let optionalHeaderSizeInt = Int(optionalHeaderSize)

    guard let characteristics = le16(bytes, coffOffset + 18) else {
      throw .invalid("PE: cannot read characteristics")
    }
    let isDLL = characteristics & 0x2000 != 0

    // Read optional header
    let optionalOffset = elfanewInt + 24
    guard optionalOffset + optionalHeaderSizeInt <= bytes.count else {
      throw .invalid("PE: optional header exceeds file bounds")
    }

    guard let magic = le16(bytes, optionalOffset) else {
      throw .invalid("PE: cannot read magic")
    }

    let (pe32Plus, imageBase, subsystemOffset, directoryCountOffset, dataDirectoriesOffset) =
      try parseOptionalHeader(bytes, magic: magic, optionalOffset: optionalOffset, optionalHeaderSize: optionalHeaderSizeInt)

    // Read subsystem
    guard let subsystemCode = le16(bytes, subsystemOffset) else {
      throw .invalid("PE: cannot read subsystem")
    }
    let subsystem = subsystemString(subsystemCode)

    // Read number of RVA and sizes
    guard let numRvaAndSizes = le32(bytes, directoryCountOffset) else {
      throw .invalid("PE: cannot read NumberOfRvaAndSizes")
    }
    // Cap at 16 and at the number of 8-byte entries that fit in SizeOfOptionalHeader.
    let directoriesRelative = dataDirectoriesOffset - optionalOffset
    let numRvaAndSizesInt = min(
      Int(numRvaAndSizes), 16, max(0, (optionalHeaderSizeInt - directoriesRelative) / 8))

    // Read section headers
    let sectionTableOffset = optionalOffset + optionalHeaderSizeInt
    var sections: [String] = []
    var sectionMap: [Section] = []

    for i in 0..<numSectionsInt {
      let sectionOffset = sectionTableOffset + i * 40
      guard sectionOffset + 40 <= bytes.count else {
        throw .invalid("PE: section header truncated")
      }

      guard let virtualSize = le32(bytes, sectionOffset + 8),
            let virtualAddr = le32(bytes, sectionOffset + 12),
            let rawSize = le32(bytes, sectionOffset + 16),
            let rawOffset = le32(bytes, sectionOffset + 20) else {
        throw .invalid("PE: cannot read section header fields")
      }

      // Read section name (8 bytes, stop at NUL)
      var name = ""
      for j in 0..<8 {
        let byte = bytes[sectionOffset + j]
        if byte == 0 { break }
        if byte >= 0x20 && byte <= 0x7E {
          name.append(Character(UnicodeScalar(byte)))
        } else {
          name.append("?")
        }
      }
      sections.append(name)

      sectionMap.append(
        Section(
          virtualAddress: Int(virtualAddr),
          virtualSize: Int(virtualSize),
          rawOffset: Int(rawOffset),
          rawSize: Int(rawSize)
        )
      )
    }

    // Read imports and delay imports
    var imports: Set<String> = []
    var delayImports: Set<String> = []

    // Imports from data directory 1
    if numRvaAndSizesInt > 1 {
      let importDirOffset = dataDirectoriesOffset + 8
      if importDirOffset + 8 <= bytes.count,
         let importRva = le32(bytes, importDirOffset),
         importRva != 0 {
        imports = try readDescriptors(bytes, rva: Int(importRva), sectionMap: sectionMap, imageBase: imageBase, stride: 20, nameOffset: 12, isDelay: false)
      }
    }

    // Delay imports from data directory 13
    if numRvaAndSizesInt > 13 {
      let delayImportDirOffset = dataDirectoriesOffset + (13 * 8)
      if delayImportDirOffset + 8 <= bytes.count,
         let delayImportRva = le32(bytes, delayImportDirOffset),
         delayImportRva != 0 {
        delayImports = try readDescriptors(
          bytes, rva: Int(delayImportRva), sectionMap: sectionMap, imageBase: imageBase, stride: 32, nameOffset: 4, isDelay: true
        )
      }
    }

    let importsList = Array(imports).sorted()
    let delayImportsList = Array(delayImports).sorted()

    return PEFacts(
      machine: machine,
      pe32Plus: pe32Plus,
      isDLL: isDLL,
      subsystem: subsystem,
      sections: sections,
      imports: importsList,
      delayImports: delayImportsList,
      timestamp: timestamp
    )
  }

  /// Reads a PE file from disk.
  ///
  /// The file must be a regular file with size <= `limit` bytes.
  /// - Throws: `HubError.io` if the file cannot be read, or `HubError.invalid` if it is malformed.
  package static func read(_ url: URL, limit: Int = 512 << 20) throws(HubError) -> PEFacts {
    do {
      var statBuf = stat()
      guard lstat(url.path, &statBuf) == 0 else {
        throw HubError.io("PE: cannot stat file")
      }
      guard (statBuf.st_mode & S_IFMT) == S_IFREG else {
        throw HubError.invalid("PE: not a regular file")
      }
      guard statBuf.st_size <= limit else {
        throw HubError.invalid("PE: file exceeds size limit")
      }

      let data = try Data(contentsOf: url)
      return try parse(Array(data))
    } catch let error as HubError {
      throw error
    } catch {
      throw HubError.io("PE: cannot read file: \(error)")
    }
  }

  // MARK: - Helper functions

  private static func machineString(_ code: UInt16) -> String {
    switch code {
    case 0x14c: return "i386"
    case 0x8664: return "x86_64"
    case 0xaa64: return "arm64"
    default: return String(format: "0x%04x", code)
    }
  }

  private static func subsystemString(_ code: UInt16) -> String {
    switch code {
    case 2: return "gui"
    case 3: return "console"
    default: return "other:\(code)"
    }
  }

  private static func parseOptionalHeader(
    _ bytes: [UInt8], magic: UInt16, optionalOffset: Int, optionalHeaderSize: Int
  ) throws(HubError) -> (pe32Plus: Bool, imageBase: UInt64, subsystemOffset: Int, directoryCountOffset: Int, dataDirectoriesOffset: Int) {
    switch magic {
    case 0x10B: // PE32
      // ImageBase at optional+28 (u32), Subsystem at optional+68, NumberOfRvaAndSizes at optional+92
      guard optionalHeaderSize >= 96, optionalOffset + 96 <= bytes.count else {
        throw .invalid("PE: PE32 optional header truncated")
      }
      guard let imageBas32 = le32(bytes, optionalOffset + 28) else {
        throw .invalid("PE: cannot read ImageBase")
      }
      let imageBase = UInt64(imageBas32)
      return (false, imageBase, optionalOffset + 68, optionalOffset + 92, optionalOffset + 96)

    case 0x20B: // PE32+
      // ImageBase at optional+24 (u64), Subsystem at optional+68, NumberOfRvaAndSizes at optional+108
      guard optionalHeaderSize >= 112, optionalOffset + 112 <= bytes.count else {
        throw .invalid("PE: PE32+ optional header truncated")
      }
      guard let imageBaseLow = le32(bytes, optionalOffset + 24),
            let imageBaseHigh = le32(bytes, optionalOffset + 28) else {
        throw .invalid("PE: cannot read ImageBase")
      }
      let imageBase = UInt64(imageBaseLow) | (UInt64(imageBaseHigh) << 32)
      return (true, imageBase, optionalOffset + 68, optionalOffset + 108, optionalOffset + 112)

    default:
      throw .invalid("PE: invalid optional header magic: 0x\(String(magic, radix: 16))")
    }
  }

  private static func rvaToOffset(_ rva: Int, sections: [Section], fileSize: Int) -> Int? {
    for section in sections {
      if rva >= section.virtualAddress && rva < section.virtualAddress + max(section.virtualSize, section.rawSize) {
        let delta = rva - section.virtualAddress
        if delta < section.rawSize {
          let offset = section.rawOffset + delta
          return offset < fileSize ? offset : nil
        }
      }
    }
    return nil
  }

  private static func readCString(_ bytes: [UInt8], offset: Int, maxBytes: Int) throws(HubError) -> String {
    guard offset >= 0 && offset < bytes.count else {
      throw .invalid("PE: string RVA unmappable")
    }

    var result = ""
    for i in 0..<maxBytes {
      let byteOffset = offset + i
      guard byteOffset < bytes.count else {
        throw .invalid("PE: string exceeds file bounds")
      }
      let byte = bytes[byteOffset]
      if byte == 0 {
        guard !result.isEmpty else {
          throw .invalid("PE: empty DLL name")
        }
        return result
      }
      guard byte >= 0x21 && byte <= 0x7E else {
        throw .invalid("PE: string contains non-ASCII byte")
      }
      result.append(Character(UnicodeScalar(byte)))
    }

    // No NUL found within maxBytes
    throw .invalid("PE: string does not terminate within limit")
  }

  private static func readDescriptors(
    _ bytes: [UInt8], rva: Int, sectionMap: [Section], imageBase: UInt64, stride: Int, nameOffset: Int, isDelay: Bool
  ) throws(HubError) -> Set<String> {
    guard let offset = rvaToOffset(rva, sections: sectionMap, fileSize: bytes.count) else {
      throw .invalid("PE: import directory RVA unmappable")
    }

    var imports: Set<String> = []
    var descriptorCount = 0
    var currentOffset = offset

    while true {
      guard currentOffset + stride <= bytes.count else {
        throw .invalid("PE: descriptor truncated")
      }

      // Check if descriptor is all-zero (end marker)
      var isZero = true
      for i in 0..<stride {
        if bytes[currentOffset + i] != 0 {
          isZero = false
          break
        }
      }
      if isZero { break }

      guard descriptorCount < maxDescriptors else {
        throw .invalid("PE: too many import descriptors")
      }

      if isDelay {
        guard let attributes = le32(bytes, currentOffset) else {
          throw .invalid("PE: cannot read delay import attributes")
        }
        guard let dllNameValue = le32(bytes, currentOffset + nameOffset) else {
          throw .invalid("PE: cannot read delay import DLL name value")
        }

        var nameRva = Int(truncatingIfNeeded: dllNameValue)
        // If Attributes bit 0 is 0, the value is a VA; subtract ImageBase
        if attributes & 1 == 0 {
          let va = UInt64(dllNameValue)
          if va < imageBase {
            // Skip this entry
            descriptorCount += 1
            currentOffset += stride
            continue
          }
          nameRva = Int(truncatingIfNeeded: va - imageBase)
        }

        let dllName = try readDLLName(bytes, rva: nameRva, sectionMap: sectionMap)
        imports.insert(dllName.lowercased())
      } else {
        // Read Name RVA
        guard let nameRva = le32(bytes, currentOffset + nameOffset) else {
          throw .invalid("PE: cannot read import name RVA")
        }

        let dllName = try readDLLName(bytes, rva: Int(truncatingIfNeeded: nameRva), sectionMap: sectionMap)
        imports.insert(dllName.lowercased())
      }

      descriptorCount += 1
      currentOffset += stride
    }

    return imports
  }

  private static func readDLLName(_ bytes: [UInt8], rva: Int, sectionMap: [Section]) throws(HubError) -> String {
    guard let offset = rvaToOffset(rva, sections: sectionMap, fileSize: bytes.count) else {
      throw .invalid("PE: DLL name RVA unmappable")
    }
    return try readCString(bytes, offset: offset, maxBytes: maxNameBytes)
  }

  // MARK: - Types

  private struct Section {
    let virtualAddress: Int
    let virtualSize: Int
    let rawOffset: Int
    let rawSize: Int
  }
}

// MARK: - Helpers for little-endian reading

private func le16(_ bytes: [UInt8], _ offset: Int) -> UInt16? {
  guard offset >= 0, offset + 2 <= bytes.count else { return nil }
  return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
}

private func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
  guard offset >= 0, offset + 4 <= bytes.count else { return nil }
  return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16
    | UInt32(bytes[offset + 3]) << 24
}

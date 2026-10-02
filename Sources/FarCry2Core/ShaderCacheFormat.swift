import Foundation
import LauncherCore

/// The container mtld3d keeps in `mtld3d_shaders.bin`, read at the level the starter needs.
///
/// The starter never decompresses a record. It reads the 16-byte file header, walks the chunks
/// exactly as `windows/core/src/shader_cache.rs` does (24-byte chunk header, a zstd frame, an xxh3
/// over the first 16 header bytes and the frame), keeps the longest run of intact chunks, and joins
/// the chunks of two caches under one header. mtld3d deduplicates and recompresses at its next start.
///
/// - Note: Record contents are DXSO shader bytecode and MSL derived from the game. They are
///   decoded only by the renderer on the player's Mac.
package enum ShaderCacheFormat {
  package static let magic = Array("MTLD3DSH".utf8)
  package static let headerLength = 16
  package static let chunkHeaderLength = 24
  /// A shader record kind is 0 through 7; 0xFE holds a pipeline recipe and 0xFF a bundle of records.
  package static let lastShaderKind: UInt8 = 7
  package static let pipelineKind: UInt8 = 0xFE
  package static let bundleKind: UInt8 = 0xFF

  /// The two integers that decide whether mtld3d keeps or wipes a cache.
  package struct Header: Equatable, Sendable {
    package let format: UInt32
    package let schema: UInt32
    package init(format: UInt32, schema: UInt32) {
      self.format = format
      self.schema = schema
    }
    package var bytes: Data {
      var data = Data(ShaderCacheFormat.magic)
      for value in [format, schema] {
        data.append(
          contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) })
      }
      return data
    }
  }

  /// What a pass over a cache found.
  package struct Layout: Equatable, Sendable {
    package let header: Header
    /// End of the last intact chunk; bytes after it are a torn write or damage and are not kept.
    package let validLength: Int
    package let chunks: Int
    package let bundles: Int
    /// A second file header inside the file (two caches concatenated); mtld3d skips it.
    package let strayHeaders: Int
    /// Chunks of a kind this version does not know; mtld3d skips them by length, so they are kept.
    package let unknownKinds: Int
    package let discardedTail: Bool
    /// Whether the file holds at least one chunk.
    package var hasRecords: Bool { chunks > 0 }
  }

  /// The header, or nil when the data is too short or is not a shader cache.
  package static func header(of data: Data) -> Header? {
    guard data.count >= headerLength, Array(data.prefix(8)) == magic else { return nil }
    return Header(format: UInt32(read(data, 8, 4)), schema: UInt32(read(data, 12, 4)))
  }

  /// Walks the chunks the way mtld3d's reader does and stops at the first torn or damaged one.
  /// - Returns: Nil when the data has no cache header.
  /// - Complexity: O(n) in the bytes, with one copy of the largest chunk.
  package static func scan(_ data: Data) -> Layout? {
    guard let header = header(of: data) else { return nil }
    let end = data.count
    var offset = headerLength
    var chunks = 0
    var bundles = 0
    var strays = 0
    var unknown = 0
    while offset + chunkHeaderLength <= end {
      if Array(data[data.startIndex + offset..<data.startIndex + offset + 8]) == magic {
        strays += 1
        offset += headerLength
        continue
      }
      let kind = data[data.startIndex + offset]
      let length = read(data, offset + 12, 4)
      let stored = UInt64(bitPattern: Int64(truncatingIfNeeded: read(data, offset + 16, 8)))
      let frameStart = offset + chunkHeaderLength
      guard frameStart + length <= end else { break }
      var hashed = Array(data[data.startIndex + offset..<data.startIndex + offset + 16])
      hashed.append(
        contentsOf: data[data.startIndex + frameStart..<data.startIndex + frameStart + length])
      guard XXH3.hash64(hashed) == stored else { break }
      if kind == bundleKind {
        bundles += 1
      } else if kind != pipelineKind, kind > lastShaderKind {
        unknown += 1
      }
      chunks += 1
      offset = frameStart + length
    }
    return Layout(
      header: header, validLength: offset, chunks: chunks, bundles: bundles, strayHeaders: strays,
      unknownKinds: unknown, discardedTail: offset < end)
  }

  /// A cache holding the intact chunks of `first` followed by those of `second`.
  ///
  /// mtld3d keeps the newest record for a key and compacts duplicates on its next start, so the join
  /// needs no record parsing. Both inputs must carry the same header and no damage that would hide the
  /// other's chunks.
  /// - Throws: When either input is not a cache, the headers differ, or the result would exceed `limit`.
  package static func joined(_ first: Data, _ second: Data, limit: Int) throws(LauncherError)
    -> Data
  {
    guard let one = scan(first), let two = scan(second) else {
      throw .operation("A shader cache could not be read.")
    }
    guard one.header == two.header else {
      throw .operation("The two shader caches were written by different renderer versions.")
    }
    guard one.validLength + two.validLength - headerLength <= limit else {
      throw .operation("The combined shader cache would exceed the \(limit / 1_048_576) MiB limit.")
    }
    var result = Data(first.prefix(one.validLength))
    result.append(
      second[(second.startIndex + headerLength)..<(second.startIndex + two.validLength)])
    return result
  }

  /// The cache cut back to its last intact chunk.
  package static func trimmed(_ data: Data, layout: Layout) -> Data {
    Data(data.prefix(layout.validLength))
  }

  /// Little-endian integer of `count` (at most 8) bytes; eight bytes may wrap into the sign bit.
  private static func read(_ data: Data, _ offset: Int, _ count: Int) -> Int {
    var value: UInt64 = 0
    for index in 0..<count {
      value |= UInt64(data[data.startIndex + offset + index]) << UInt64(8 * index)
    }
    return Int(truncatingIfNeeded: value)
  }
}

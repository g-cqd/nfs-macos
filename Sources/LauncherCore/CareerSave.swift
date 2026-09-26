import CryptoKit
import Foundation

/// Validated PC 1.3 profile. MD5 and EA CRCs are file-format checks, not security primitives.
package struct CareerSave {
  package private(set) var data: Data
  package static let size = 63_596
  package var cash: UInt32 { word(0x4039) }
  package var alias: String {
    String(decoding: data[0x5a31..<0x5a55].prefix { $0 != 0 }, as: UTF8.self)
  }
  package var fingerprint: String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  package init(_ bytes: Data) throws(LauncherError) {
    guard bytes.count == Self.size, bytes.prefix(4) == Data("20CM".utf8) else {
      throw .operation("Expected a 63,596-byte Most Wanted PC save.")
    }
    data = bytes
    guard word(4) == Self.size else { throw .operation("The save size field is invalid.") }
    guard Data(Insecure.MD5.hash(data: data[0x34..<(Self.size - 16)])) == data.suffix(16) else {
      throw .operation("The save MD5 check failed.")
    }
    for (offset, range) in [(0x10, 0x1c..<0x24), (0x14, 0x24..<Self.size), (0x18, 0..<0x18)] {
      guard word(offset) == Self.crc(data[range]) else {
        throw .operation("The save CRC check failed at \(offset).")
      }
    }
  }

  package func cars() throws(LauncherError) -> [GarageCar] {
    var cars: [GarageCar] = []
    var careers: Set<Int> = []
    var parts: Set<Int> = []
    for row in 0..<119 {
      let offset = 0x6219 + row * 20
      guard data[offset + 18] == 205, data[offset + 19] == 205 else {
        throw .operation("Unsupported car registry layout.")
      }
      let number = word(offset)
      if number == UInt32.max { continue }
      guard number == row + 81 else { throw .operation("Unsupported car registry numbering.") }
      let flags = Int(data[offset + 12]) | Int(data[offset + 13]) << 8
      guard flags == 2 || flags == 66 else { continue }
      let part = Int(data[offset + 16])
      let career = Int(data[offset + 17])
      guard (31..<75).contains(part), (0..<25).contains(career), careers.insert(career).inserted,
        parts.insert(part).inserted
      else { throw .operation("The career contains invalid or shared car records.") }
      let block = 0x9ccd + (part - 31) * 408
      let record = 0xe2ed + career * 56
      guard data[block + 404..<block + 408] == Data([UInt8(part), 205, 205, 205]),
        data[record] == career, data[record + 1] == 205, data[record + 7] == 0,
        data[record + 8] == 0, data[record + 9] == 0, data[record + 10] == 205,
        data[record + 11] == 205
      else { throw .operation("The car has an invalid parts or pursuit record.") }
      let signature = data[offset + 4..<offset + 12].map { String(format: "%02x", $0) }.joined()
      let heat = Float(bitPattern: word(record + 12))
      guard heat.isFinite else { throw .operation("The car heat value is invalid.") }
      cars.append(
        GarageCar(
          id: Int(number), name: CarModel.all[signature]?.name ?? signature, signature: signature,
          partsSlot: part, careerSlot: career, levels: (0..<7).map { word(block + 0x118 + $0 * 4) },
          junkman: word(block + 0x134), heat: heat, bounty: word(record + 16)))
    }
    return cars
  }

  /// Changes only the profile name and integrity fields in a validated copy.
  /// - Complexity: O(save size), bounded by the PC profile format.
  package func renamed(_ name: String) throws(LauncherError) -> Self {
    guard ProfileName.isValid(name), name.utf8.count <= 16 else {
      throw .operation("Use 1–16 ASCII characters without path separators for the player name.")
    }
    var updated = self
    updated.data.replaceSubrange(0x5a31..<0x5a55, with: repeatElement(UInt8(0), count: 36))
    updated.data.replaceSubrange(0x5a31..<0x5a31 + name.utf8.count, with: name.utf8)
    updated.repairIntegrity()
    return try Self(updated.data)
  }

  /// Edits an independent copy and revalidates all checksums before returning it.
  /// - Complexity: O(save size); storage is bounded by the fixed profile size.
  package func applying(_ cheat: SaveCheat) throws(LauncherError) -> Self {
    var updated = self
    switch cheat {
    case .money(let operation, let amount): try updated.changeMoney(operation, amount: amount)
    case .car(let id, let levels, let junkman, let heat, let bounty):
      try updated.changeCar(id, levels: levels, junkman: junkman, heat: heat, bounty: bounty)
    case .addCar(let signature, let count): try updated.addCar(signature, count: count)
    case .duplicate(let id, let count): try updated.duplicate(id, count: count)
    }
    updated.repairIntegrity()
    return try Self(updated.data)
  }

  private mutating func changeMoney(_ operation: MoneyOperation, amount: UInt64)
    throws(LauncherError)
  {
    setWord(0x4039, try operation.result(current: cash, amount: amount))
  }

  private mutating func changeCar(
    _ id: Int, levels: [UInt32], junkman: UInt32, heat: Float, bounty: UInt32
  ) throws(LauncherError) {
    guard let car = try cars().first(where: { $0.id == id }), let limits = car.limits,
      levels.count == 7, zip(levels, limits).allSatisfy({ $0 <= $1 }), junkman <= 127,
      heat.isFinite, (0...5).contains(heat), junkman & 32 == 0 || levels[5] > 0,
      junkman & 64 == 0 || levels[6] > 0
    else { throw .operation("Unsupported car upgrade, Junkman requirement, or heat value.") }
    let block = 0x9ccd + (car.partsSlot - 31) * 408
    for (index, level) in levels.enumerated() { setWord(block + 0x118 + index * 4, level) }
    setWord(block + 0x134, junkman)
    let record = 0xe2ed + car.careerSlot * 56
    setWord(record + 12, heat.bitPattern)
    setWord(record + 16, bounty)
  }

  private mutating func addCar(_ signature: String, count: Int) throws(LauncherError) {
    let existing = try cars()
    guard CarModel.all[signature] != nil, (1...25).contains(count), existing.count + count <= 25
    else {
      throw .operation("Select a catalog model and a quantity that fits the 25-car garage.")
    }
    let stockParts = try StockCarParts.block(for: signature)
    var signatureBytes = Data()
    for index in stride(from: 0, to: 16, by: 2) {
      let start = signature.index(signature.startIndex, offsetBy: index)
      let end = signature.index(start, offsetBy: 2)
      guard let byte = UInt8(signature[start..<end], radix: 16) else {
        throw .operation("Invalid catalog signature.")
      }
      signatureBytes.append(byte)
    }
    for _ in 0..<count {
      let allocation = try GarageAllocation(data: data)
      let row = 0x6219 + allocation.row * 20
      data.replaceSubrange(row..<row + 20, with: repeatElement(UInt8(0), count: 20))
      setWord(row, UInt32(allocation.row + 81))
      data.replaceSubrange(row + 4..<row + 12, with: signatureBytes)
      data[row + 12] = 2
      data[row + 14] = 15
      data[row + 16] = UInt8(allocation.part)
      data[row + 17] = UInt8(allocation.career)
      data[row + 18] = 205
      data[row + 19] = 205
      let part = 0x9ccd + (allocation.part - 31) * 408
      data.replaceSubrange(part..<part + 0x116, with: stockParts)
      data[part + 0x116] = 205
      data[part + 0x117] = 205
      data.replaceSubrange(part + 0x118..<part + 404, with: repeatElement(UInt8(0), count: 124))
      data.replaceSubrange(part + 404..<part + 408, with: [UInt8(allocation.part), 205, 205, 205])
      let record = 0xe2ed + allocation.career * 56
      data.replaceSubrange(record..<record + 56, with: repeatElement(UInt8(0), count: 56))
      data[record] = UInt8(allocation.career)
      data[record + 1] = 205
      data[record + 2] = 3
      data[record + 10] = 205
      data[record + 11] = 205
      setWord(record + 12, Float(1).bitPattern)
      if existing.isEmpty { data[0x4034] = UInt8(allocation.row + 81) }
    }
    _ = try cars()
  }

  private mutating func duplicate(_ id: Int, count: Int) throws(LauncherError) {
    let cars = try cars()
    guard (1...25).contains(count), cars.count + count <= 25,
      let car = cars.first(where: { $0.id == id })
    else { throw .operation("Select a career car and a count that fits the 25-car garage.") }
    let sourceRow = 0x6219 + (car.id - 81) * 20
    // An advanced visual sidecar needs a separate allocator; reject rather than duplicate its pointer.
    let sourcePart = 0x9ccd + (car.partsSlot - 31) * 408
    guard data[sourcePart + 0x9c] == 255, data[sourcePart + 0x9d] == 255 else {
      throw .operation(
        "This car uses advanced visual data and cannot be duplicated by this editor.")
    }
    for _ in 0..<count {
      let allocation = try GarageAllocation(data: data)
      let row = allocation.row
      let part = allocation.part
      let career = allocation.career
      let destination = 0x6219 + row * 20
      data.replaceSubrange(destination..<destination + 20, with: data[sourceRow..<sourceRow + 20])
      setWord(destination, UInt32(row + 81))
      data[destination + 16] = UInt8(part)
      data[destination + 17] = UInt8(career)
      let partOffset = 0x9ccd + (part - 31) * 408
      data.replaceSubrange(partOffset..<partOffset + 408, with: data[sourcePart..<sourcePart + 408])
      data[partOffset + 404] = UInt8(part)
      let record = 0xe2ed + career * 56
      data.replaceSubrange(record..<record + 56, with: repeatElement(UInt8(0), count: 56))
      data[record] = UInt8(career)
      data[record + 1] = 205
      data[record + 2] = 3
      data[record + 10] = 205
      data[record + 11] = 205
      setWord(record + 12, Float(1).bitPattern)
    }
    _ = try self.cars()
  }

  private func word(_ offset: Int) -> UInt32 {
    // All offsets come from fixed fields or records checked against the fixed file size.
    UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(
      data[offset + 3]) << 24
  }

  private mutating func setWord(_ offset: Int, _ value: UInt32) {
    for index in 0..<4 { data[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
  }

  private mutating func repairIntegrity() {
    data.replaceSubrange(
      Self.size - 16..<Self.size, with: Data(Insecure.MD5.hash(data: data[0x34..<Self.size - 16])))
    setWord(0x14, Self.crc(data[0x24..<Self.size]))
    setWord(0x18, Self.crc(data[0..<0x18]))
  }

  private static func crc(_ bytes: Data.SubSequence) -> UInt32 {
    var value = bytes.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } ^ UInt32.max
    for byte in bytes.dropFirst(4) {
      for _ in 0..<8 { value = value << 1 ^ (value & 0x8000_0000 != 0 ? 0x04c1_1db7 : 0) }
      value ^= UInt32(byte)
    }
    return value ^ UInt32.max
  }
}

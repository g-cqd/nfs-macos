import Foundation
import Testing

@testable import LauncherCore

struct GarageCatalogTests {
  @Test(arguments: [
    ("4e4acc23b35f084e", [5082, 5127, 5242]),
    ("929986c4d43d0667", [10507, 10552, 10667]),
    ("36493d3136493d31", [3225, 3270, 3385]),
  ])
  func `new cars reference their stock body and wheels`(model: (String, [Int])) throws {
    let sut = try CareerSave(CareerSaveTests.fixture()).applying(
      .addCar(signature: model.0, count: 1))
    let car = try #require(sut.cars().last)
    let block = 0x9ccd + (car.partsSlot - 31) * 408
    for (slot, expected) in zip([0, 23, 66], model.1) {
      let offset = block + slot * 2
      #expect(Int(sut.data[offset]) | Int(sut.data[offset + 1]) << 8 == expected)
    }
  }

  @Test(arguments: CarModel.all.keys.sorted())
  func `adds a stock catalog car without changing existing progress`(signature: String) throws {
    let original = try CareerSave(CareerSaveTests.fixture())
    let sut = try original.applying(.addCar(signature: signature, count: 1))
    let cars = try sut.cars()
    #expect(cars.count == 2)
    #expect(cars[1].signature == signature)
    #expect(cars[1].levels == [0, 0, 0, 0, 0, 0, 0])
    #expect(cars[1].junkman == 0)
    #expect(cars[1].partsSlot != cars[0].partsSlot)
    #expect(cars[1].careerSlot != cars[0].careerSlot)
    let block = 0x9ccd + (cars[1].partsSlot - 31) * 408
    #expect(sut.data[block..<block + 278] == (try Self.nativeStock(signature)))
    #expect(sut.cash == original.cash)
    #expect(sut.data[0x4034] == original.data[0x4034])
    #expect(sut.data[0x6219..<0x622d] == original.data[0x6219..<0x622d])
  }

  private static func nativeStock(_ signature: String) throws -> Data {
    let url = try #require(
      Bundle.module.url(
        forResource: "stock-capture", withExtension: "csv", subdirectory: "Fixtures"))
    let capture = try String(contentsOf: url, encoding: .ascii)
    let row = try #require(capture.split(separator: "\n").first { $0.hasPrefix(signature + ",") })
    let fields = row.split(separator: ",")
    #expect(fields.count == 141)
    var bytes = Data(capacity: 278)
    for field in fields.dropFirst(2) {
      let part = try #require(UInt16(field))
      bytes.append(UInt8(truncatingIfNeeded: part))
      bytes.append(UInt8(truncatingIfNeeded: part >> 8))
    }
    return bytes
  }

  @Test func `rejects unknown models and capacity overflow without changing input`() throws {
    let bytes = try CareerSaveTests.fixture()
    let sut = try CareerSave(bytes)
    #expect(throws: LauncherError.self) { try sut.applying(.addCar(signature: "bad", count: 1)) }
    #expect(throws: LauncherError.self) {
      try sut.applying(.addCar(signature: "4e4acc23b35f084e", count: 25))
    }
    #expect(throws: LauncherError.self) {
      try sut.applying(.addCar(signature: "4e4acc23b35f084e", count: 0))
    }
    #expect(sut.data == bytes)
    let full = try sut.applying(.addCar(signature: "4e4acc23b35f084e", count: 24))
    #expect(try full.cars().count == 25)
    #expect(Set(try full.cars().map(\.partsSlot)).count == 25)
  }
}

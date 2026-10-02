import Foundation
import GameFixtures
import Testing

@testable import LauncherCore

struct PortableExecutableTests {
  @Test
  func `reads machine, file version and version strings from a synthetic image`() throws {
    var options = PEFixture.Options()
    options.fileVersion = (1, 0, 3, 7)
    options.strings = [("CompanyName", "Example Studio"), ("ProductName", "Example Game")]
    let image = try PortableExecutable.parse(PEFixture.make(options))
    #expect(image.machine == PortableExecutable.machineI386)
    #expect(image.isDynamicLibrary == false)
    #expect(image.fileVersion == "1.0.3.7")
    #expect(image.strings["CompanyName"] == "Example Studio")
    #expect(image.strings["ProductName"] == "Example Game")
  }

  @Test
  func `version strings are bounded in bytes however many combining marks one letter has`() throws {
    var options = PEFixture.Options()
    options.strings = [("ProductName", "e" + String(repeating: "\u{0301}", count: 20_000))]
    let image = try PortableExecutable.parse(PEFixture.make(options))
    let product = try #require(image.strings["ProductName"])
    #expect(product.utf8.count <= 128)
    #expect(!product.isEmpty)
  }

  @Test
  func `an image without a version resource is still recognised`() throws {
    var options = PEFixture.Options()
    options.fileVersion = nil
    let image = try PortableExecutable.parse(PEFixture.make(options))
    #expect(image.fileVersion == nil)
    #expect(image.strings.isEmpty)
  }

  @Test
  func `distinguishes 64-bit images and libraries`() throws {
    var options = PEFixture.Options()
    options.machine = PortableExecutable.machineAMD64
    options.pe32Plus = true
    options.dynamicLibrary = true
    let image = try PortableExecutable.parse(PEFixture.make(options))
    #expect(image.machine == PortableExecutable.machineAMD64)
    #expect(image.isDynamicLibrary)
  }

  @Test(arguments: [0, 1, 2, 63, 64, 0x80, 0x84, 0x98, 0x100, 0x178, 0x19F])
  func `a header cut short is rejected without reading past the end`(length: Int) {
    let image = Array(PEFixture.make().prefix(length))
    #expect(throws: LauncherError.self) { try PortableExecutable.parse(image) }
  }

  @Test(arguments: [0x1A0, 0x205, 0x210])
  func `a resource cut short yields no version instead of a trap`(length: Int) throws {
    let image = Array(PEFixture.make().prefix(length))
    let parsed = try PortableExecutable.parse(image)
    #expect(parsed.machine == PortableExecutable.machineI386)
    #expect(parsed.fileVersion == nil)
  }

  @Test
  func `rejects text, a bad signature and an absurd header offset`() {
    #expect(throws: LauncherError.self) { try PortableExecutable.parse(Array("hello".utf8)) }
    var wrongSignature = PEFixture.make()
    wrongSignature[0x80] = 0
    #expect(throws: LauncherError.self) { try PortableExecutable.parse(wrongSignature) }
    var farHeader = PEFixture.make()
    farHeader[0x3C] = 0xFF
    farHeader[0x3D] = 0xFF
    farHeader[0x3E] = 0xFF
    farHeader[0x3F] = 0x7F
    #expect(throws: LauncherError.self) { try PortableExecutable.parse(farHeader) }
  }

  @Test
  func `hostile resource offsets are ignored instead of read`() throws {
    var image = PEFixture.make()
    // Point the resource directory far outside the file.
    let directories = 0x80 + 24 + 96
    image[directories + 16] = 0xFF
    image[directories + 17] = 0xFF
    image[directories + 18] = 0xFF
    image[directories + 19] = 0x7F
    let parsed = try PortableExecutable.parse(image)
    #expect(parsed.fileVersion == nil)
  }
}

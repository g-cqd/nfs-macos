import Foundation
import Testing

@testable import FarCry2Core
@testable import LauncherCore

struct GamerProfileDocumentTests {
  private let render = ["RenderProfile"]
  private func document(_ text: String = FarCry2Fixture.profileXML) throws -> GamerProfileDocument {
    try GamerProfileDocument(Data(text.utf8))
  }

  @Test
  func `unchanged documents round-trip byte for byte`() throws {
    let sut = try document()
    #expect(sut.data == Data(FarCry2Fixture.profileXML.utf8))
  }

  @Test
  func `reads attribute values and ignores commented-out elements`() throws {
    let sut = try document()
    #expect(sut.values(.init(render, "Platform")) == ["d3d10a"])
    #expect(sut.values(.init(render, "ResolutionX")) == ["1440"])
    #expect(sut.values(.init(["CustomQuality", "quality"], "ResolutionX")) == ["800", "800"])
    #expect(sut.values(.init(["Audio"], "Volume")) == ["0.8"])
    #expect(sut.hasElement(["CustomQuality", "quality"]))
    #expect(!sut.hasElement(["quality", "CustomQuality"]))
  }

  @Test
  func `changes only the requested values and leaves every other byte alone`() throws {
    var sut = try document()
    let count = try sut.set("d3d9", for: .init(render, "Platform"))
    #expect(count == 1)
    let expected = FarCry2Fixture.profileXML.replacingOccurrences(
      of: "Platform=\"d3d10a\"", with: "Platform=\"d3d9\"")
    #expect(String(decoding: sut.data, as: UTF8.self) == expected)
    #expect(
      String(decoding: sut.data, as: UTF8.self).contains("<!-- <RenderProfile Platform=\"d3d10\">"))
  }

  @Test
  func `rewrites every matching nested element and never creates attributes`() throws {
    var sut = try document()
    #expect(try sut.set("2560", for: .init(["CustomQuality", "quality"], "ResolutionX")) == 2)
    #expect(sut.values(.init(["CustomQuality", "quality"], "ResolutionX")) == ["2560", "2560"])
    #expect(try sut.set("1", for: .init(render, "NoSuchAttribute")) == 0)
    #expect(try sut.set("1", for: .init(["Missing"], "Platform")) == 0)
    #expect(!String(decoding: sut.data, as: UTF8.self).contains("NoSuchAttribute"))
  }

  @Test
  func `setting is idempotent and longer or shorter values keep the file well-formed`() throws {
    var sut = try document()
    try sut.set("3840", for: .init(render, "ResolutionX"))
    let once = sut.data
    try sut.set("3840", for: .init(render, "ResolutionX"))
    #expect(sut.data == once)
    try sut.set("1", for: .init(render, "ResolutionX"))
    #expect(sut.values(.init(render, "ResolutionX")) == ["1"])
    #expect(sut.values(.init(render, "ResolutionY")) == ["900"])
  }

  @Test
  func `single quotes, self-closing tags, CDATA and processing instructions are understood`() throws
  {
    let text = "<?xml version='1.0'?><A><![CDATA[ <B x=\"1\"> ]]><B x='2' y = \"3\"/><C></C></A>"
    var sut = try document(text)
    #expect(sut.values(.init(["B"], "x")) == ["2"])
    #expect(sut.values(.init(["B"], "y")) == ["3"])
    try sut.set("9", for: .init(["B"], "x"))
    #expect(
      String(decoding: sut.data, as: UTF8.self)
        == text.replacingOccurrences(of: "x='2'", with: "x='9'"))
  }

  @Test
  func `preserves a UTF-8 byte order mark and UTF-16 encodings`() throws {
    let bom = Data([0xEF, 0xBB, 0xBF]) + Data(FarCry2Fixture.profileXML.utf8)
    var utf8 = try GamerProfileDocument(bom)
    #expect(utf8.data == bom)
    try utf8.set("d3d9", for: .init(render, "Platform"))
    #expect(utf8.data.starts(with: [0xEF, 0xBB, 0xBF]))
    for (encoding, mark) in [
      (String.Encoding.utf16LittleEndian, [UInt8(0xFF), 0xFE]), (.utf16BigEndian, [0xFE, 0xFF]),
    ] {
      let body = try #require(FarCry2Fixture.profileXML.data(using: encoding))
      let original = Data(mark) + body
      var sut = try GamerProfileDocument(original)
      #expect(sut.data == original)
      try sut.set("d3d9", for: .init(render, "Platform"))
      #expect(sut.data.starts(with: mark))
      let reread = try GamerProfileDocument(sut.data)
      #expect(reread.values(.init(render, "Platform")) == ["d3d9"])
    }
  }

  @Test(arguments: [
    "<!DOCTYPE a [<!ENTITY x \"y\">]><a/>", "<a><b></a>", "<a>", "<a b=1/>", "<a b=\"1/>",
    "", "plain text", "<a b=\"<\"/>", "</a>", "<a><!-- unterminated </a>",
  ])
  func `rejects documents that are not well-formed or use a DOCTYPE`(text: String) {
    #expect(throws: LauncherError.self) { try GamerProfileDocument(Data(text.utf8)) }
  }

  @Test
  func `rejects NUL bytes, invalid UTF-8, oversized and over-deep input`() {
    #expect(throws: LauncherError.self) { try GamerProfileDocument(Data("<a/>\0".utf8)) }
    #expect(throws: LauncherError.self) {
      try GamerProfileDocument(Data([0x3C, 0x61, 0xFF, 0x2F, 0x3E]))
    }
    #expect(throws: LauncherError.self) {
      try GamerProfileDocument(Data(repeating: 0x20, count: 1_048_577))
    }
    let deep = String(repeating: "<a>", count: 65) + String(repeating: "</a>", count: 65)
    #expect(throws: LauncherError.self) { try GamerProfileDocument(Data(deep.utf8)) }
  }

  @Test(arguments: [
    "", "a b", "1\"2", "<x>", "a&b", "x;y", "line\nbreak", String(repeating: "a", count: 65),
  ])
  func `refuses values that would need escaping or could inject markup`(value: String) throws {
    var sut = try document()
    #expect(throws: LauncherError.self) { try sut.set(value, for: .init(render, "Platform")) }
    #expect(sut.data == Data(FarCry2Fixture.profileXML.utf8))
  }

  @Test
  func `values containing entities are not trusted`() throws {
    let sut = try document("<a><b c=\"&amp;\"/></a>")
    #expect(sut.values(.init(["b"], "c")).isEmpty)
  }
}

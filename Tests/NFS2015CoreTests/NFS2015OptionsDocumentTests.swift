import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

struct NFS2015OptionsDocumentTests {
  static let endings: [TextVariant] = [
    TextVariant("LF", OptionsFixture.text()),
    TextVariant("CRLF", OptionsFixture.text(lineEnding: "\r\n")),
    TextVariant("LF without a final terminator", OptionsFixture.text(terminated: false)),
    TextVariant(
      "CRLF without a final terminator", OptionsFixture.text(lineEnding: "\r\n", terminated: false)),
    TextVariant(
      "mixed",
      OptionsFixture.lines.enumerated().map {
        $0.element + ($0.offset.isMultiple(of: 3) ? "\r\n" : "\n")
      }.joined()),
  ]

  @Test(arguments: endings)
  func `writes back exactly the bytes it read`(variant: TextVariant) throws {
    let original = Data(variant.text.utf8)
    let document = try ProfileOptionsDocument(data: original)
    #expect(document.data == original)
    #expect(document.keys == OptionsFixture.lines.map { String($0.split(separator: " ")[0]) })
  }

  @Test(arguments: endings)
  func `changes only the targeted values and keeps every line ending`(
    variant: TextVariant
  ) throws {
    let document = try ProfileOptionsDocument(data: Data(variant.text.utf8))
    let changed = try document.applying([
      "GstRender.VSyncEnabled": "1", "GstRender.ResolutionWidth": "1920",
    ])
    var expected = OptionsFixture.replacing("GstRender.VSyncEnabled", with: "1", in: variant.text)
    expected = OptionsFixture.replacing("GstRender.ResolutionWidth", with: "1920", in: expected)
    #expect(String(decoding: changed.data, as: UTF8.self) == expected)
    #expect(
      changed.isIdentical(
        to: document, except: ["GstRender.VSyncEnabled", "GstRender.ResolutionWidth"]))
    #expect(
      changed.changedKeys(from: document) == [
        "GstRender.ResolutionWidth", "GstRender.VSyncEnabled",
      ])
  }

  @Test
  func `keeps every unknown line the game wrote, in order`() throws {
    let document = try ProfileOptionsDocument(data: OptionsFixture.data())
    let changed = try document.applying(["GstRender.FilmGrain": "0"])
    let unknown = OptionsFixture.lines.filter {
      $0.hasPrefix("GstKeyBinding") || $0.contains("Joystick")
    }
    let after = String(decoding: changed.data, as: UTF8.self).split(separator: "\n").map(
      String.init)
    #expect(after.filter { unknown.contains($0) } == unknown)
    #expect(after.count == OptionsFixture.lines.count)
    #expect(changed.value("GstRender.FilmGrain") == "0")
  }

  static let refused: [TextVariant] = [
    TextVariant("empty", ""),
    TextVariant("blank line", OptionsFixture.text() + "\n"),
    TextVariant(
      "blank line inside", OptionsFixture.text(lines: ["GstRender.A 1", "", "GstRender.B 2"])),
    TextVariant(
      "a text value", OptionsFixture.text(lines: ["GstRender.A 1", "GstAudio.Name Driver"])),
    TextVariant(
      "a key outside the game's families",
      OptionsFixture.text(lines: ["GstRender.A 1", "Other.B 2"])),
    TextVariant("a repeated key", OptionsFixture.text(lines: ["GstRender.A 1", "GstRender.A 2"])),
    TextVariant("two spaces", OptionsFixture.text(lines: ["GstRender.A  1"])),
    TextVariant("no value", OptionsFixture.text(lines: ["GstRender.A"])),
    TextVariant("a lone carriage return", "GstRender.A 1\rGstRender.B 2\n"),
    TextVariant("a trailing space", OptionsFixture.text(lines: ["GstRender.A 1 "])),
    TextVariant("a non-ASCII byte", OptionsFixture.text(lines: ["GstRender.A 1", "GstAudio.B é"])),
    TextVariant("a NUL byte", "GstRender.A 1\0\n"),
    TextVariant("a tab", "GstRender.A\t1\n"),
    TextVariant("an exponent", OptionsFixture.text(lines: ["GstRender.A 1e3"])),
    TextVariant("a trailing point", OptionsFixture.text(lines: ["GstRender.A 1."])),
    TextVariant("a lone minus", OptionsFixture.text(lines: ["GstRender.A -"])),
    TextVariant("no render option", OptionsFixture.text(lines: ["GstAudio.A 1"])),
    TextVariant("a binary blob", "FBCHUNKS\u{1}\u{2}"),
  ]

  @Test(arguments: refused)
  func `refuses a layout it has not validated`(variant: TextVariant) {
    let error = #expect(throws: LauncherError.self) {
      try ProfileOptionsDocument(data: Data(variant.text.utf8))
    }
    #expect(error?.localizedDescription.contains("Nothing was changed") == true)
  }

  @Test
  func `refuses a file over the size, line and line-length limits`() {
    let large = Data(repeating: 0x41, count: ProfileOptionsDocument.byteLimit + 1)
    #expect(throws: LauncherError.self) { try ProfileOptionsDocument(data: large) }
    let many = (0..<(ProfileOptionsDocument.lineLimit + 1)).map { "GstRender.Key\($0) 1" }
    #expect(throws: LauncherError.self) {
      try ProfileOptionsDocument(text: OptionsFixture.text(lines: many))
    }
    let long = "GstRender." + String(repeating: "A", count: 600) + " 1"
    #expect(throws: LauncherError.self) { try ProfileOptionsDocument(text: long + "\n") }
  }

  @Test
  func `refuses to invent a key the game has not written`() throws {
    let document = try ProfileOptionsDocument(data: Data("GstRender.VSyncEnabled 0\n".utf8))
    let error = #expect(throws: LauncherError.self) {
      try document.applying(["GstRender.PresentInterval": "1"])
    }
    #expect(error?.localizedDescription.contains("GstRender.PresentInterval") == true)
  }

  @Test(arguments: ["", "-", "1.", ".5", "1e3", "0x10", "1 2", "on", "1\n2", "nan", "١"])
  func `refuses a replacement value the game's own lines cannot hold`(value: String) throws {
    let document = try ProfileOptionsDocument(data: OptionsFixture.data())
    #expect(throws: LauncherError.self) { try document.applying(["GstRender.FilmGrain": value]) }
  }

  @Test(arguments: ["", "Gst Render", "GstRender.Film\nGrain", "GstRender.Film=Grain"])
  func `refuses a replacement name the game's own lines cannot hold`(key: String) throws {
    let document = try ProfileOptionsDocument(data: OptionsFixture.data())
    #expect(throws: LauncherError.self) { try document.applying([key: "1"]) }
  }

  @Test(arguments: [
    ("60", "60.000000", true), ("0.5", "0.500000", true), ("1", "2", false), ("a", "a", true),
    ("a", "b", false),
  ])
  func `compares recorded numbers by value`(left: String, right: String, same: Bool) {
    #expect(ProfileOptionsDocument.isSameNumber(left, right) == same)
  }
}

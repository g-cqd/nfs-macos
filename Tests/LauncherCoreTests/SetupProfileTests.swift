import Foundation
import Testing

@testable import LauncherCore

struct SetupProfileTests {
  @Test func `setup shares graphics and analog mappings without career edits`() throws {
    var source = GameSettings()
    source.values["scale"] = "0.75"
    source.mappingProfile = "Private Player"
    source.unlockAll = true
    source.mappings.bindings["GAMEACTION_GAS"] = "XINPUT_GAMEPAD_LT"
    let bytes = try SetupProfile(settings: source).encoded()
    #expect(!String(decoding: bytes, as: UTF8.self).contains("Private Player"))
    var destination = GameSettings()
    destination.unlockAll = false
    destination.mappingProfile = "Friend"
    let sut = try SetupProfile.read(bytes).applying(to: destination)
    #expect(sut.value("scale") == "0.75")
    #expect(sut.mappings.value(for: "GAMEACTION_GAS") == "XINPUT_GAMEPAD_LT")
    #expect(sut.mappingProfile == "Friend")
    #expect(!sut.unlockAll)
  }

  @Test(arguments: [
    "{}", "{\"format\":\"other\",\"version\":1,\"values\":{},\"mappings\":{\"bindings\":{}}}",
    "{\"format\":\"nfsmw.setup\",\"version\":2,\"values\":{},\"mappings\":{\"bindings\":{}}}",
    "{\"format\":\"nfsmw.setup\",\"version\":1,\"values\":{\"scale\":\"99\"},\"mappings\":{\"bindings\":{}}}",
  ])
  func `rejects malformed unsupported and invalid profiles`(text: String) {
    #expect(throws: LauncherError.self) { try SetupProfile.read(Data(text.utf8)) }
  }
}

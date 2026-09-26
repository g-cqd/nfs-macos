import Testing

@testable import LauncherCore
@testable import NFSMWLauncher

@MainActor
struct SaveEditorModelTests {
  @Test(arguments: ["current", ""])
  func `profile imports distinguish live saves from removed backup entries`(fingerprint: String) {
    let sut = SaveEditorModel()
    sut.load([
      ProfileSummary(
        id: "Player", fingerprint: fingerprint, cash: nil, cars: [], backups: [], issue: nil)
    ])
    #expect(
      sut.fingerprintForReplacement(of: "Player") == (fingerprint.isEmpty ? nil : fingerprint))
    #expect(sut.fingerprintForReplacement(of: "NewPlayer") == nil)
  }

  @Test func `search keeps the picker selection valid and prevents adding hidden models`() throws {
    let sut = SaveEditorModel()
    sut.load([
      ProfileSummary(
        id: "Player", fingerprint: "current", cash: 10, cars: [], backups: [], issue: nil)
    ])
    sut.carSearch = "Porsche"
    #expect(sut.catalogCars.contains { $0.id == sut.newCarSignature })
    sut.carSearch = "model that does not exist"
    #expect(sut.newCarSignature.isEmpty)
    #expect(throws: LauncherError.self) { try sut.addCarRequest() }
  }

  @Test func `catalog search and requests keep the selected career`() throws {
    let sut = SaveEditorModel()
    sut.load([
      ProfileSummary(
        id: "Player", fingerprint: "current", cash: 10, cars: [], backups: [], issue: nil)
    ])
    sut.carSearch = "BMW"
    #expect(!sut.catalogCars.isEmpty)
    #expect(sut.catalogCars.allSatisfy { $0.title.contains("BMW") })
    sut.newCarSignature = "4e4acc23b35f084e"
    sut.newCarCount = "2"
    let request = try sut.addCarRequest()
    guard case .cheat(let profile, let expected, .addCar(let signature, let count)) = request else {
      #expect(Bool(false), "Expected a selected-profile car addition")
      return
    }
    #expect(profile == "Player")
    #expect(expected == "current")
    #expect(signature == "4e4acc23b35f084e")
    #expect(count == 2)
    sut.newCarCount = "26"
    #expect(throws: LauncherError.self) { try sut.addCarRequest() }
  }

  @Test func `removed profiles can restore but cannot be edited or exported`() throws {
    let sut = SaveEditorModel()
    sut.load([
      ProfileSummary(
        id: "Removed", fingerprint: "", cash: nil, cars: [], backups: ["point.save"], issue: nil)
    ])
    #expect(!sut.canEdit)
    #expect(!sut.hasLiveProfile)
    let request = try sut.restoreRequest()
    guard case .restore(_, _, let expected) = request else {
      #expect(Bool(false), "Expected a restore request")
      return
    }
    #expect(expected == nil)
    #expect(throws: LauncherError.self) { try sut.removeRequest() }
  }
}

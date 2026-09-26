import Foundation
import LauncherCore
import Observation
import SwiftUI

@MainActor @Observable
final class SaveEditorModel {
  private(set) var profiles: [ProfileSummary] = []
  var selectedProfile = "" { didSet { selectProfile() } }
  var selectedCar = 0 { didSet { loadCar() } }
  var selectedBackup = ""
  var moneyOperation = MoneyOperation.set
  var amount = "0"
  var copies = "1"
  var newProfileName = ""
  var removeConfirmation = false
  var carSearch = "" {
    didSet {
      if !catalogCars.contains(where: { $0.id == newCarSignature }) {
        newCarSignature = catalogCars.first?.id ?? ""
      }
    }
  }
  var newCarSignature = "4e4acc23b35f084e"
  var newCarCount = "1"
  var heat = "1"
  var bounty = "0"
  private var levels: [UInt32] = []
  private var junkman: UInt32 = 0

  var profile: ProfileSummary? { profiles.first { $0.id == selectedProfile } }
  var cars: [GarageCar] { profile?.cars ?? [] }
  var car: GarageCar? { cars.first { $0.id == selectedCar } }
  var backupNames: [String] { profile?.backups ?? [] }
  var hasLiveProfile: Bool { profile != nil && profile?.isRemoved == false }
  var catalogCars: [SettingChoice] {
    Self.allCatalogCars.filter {
      carSearch.isEmpty || $0.title.lowercased().contains(carSearch.lowercased())
    }
  }
  private static let allCatalogCars: [SettingChoice] = CarModel.all.map {
    SettingChoice($0.key, $0.value.name)
  }
  .sorted { $0.title == $1.title ? $0.id < $1.id : $0.title < $1.title }
  var garageCapacity: String { "\(cars.count) of 25 career slots used" }
  var canCreateProfile: Bool {
    ProfileName.isValid(newProfileName) && newProfileName.utf8.count <= 16
      && !profiles.contains { $0.id.lowercased() == newProfileName.lowercased() }
  }
  var canEdit: Bool { profile?.cash != nil && profile?.issue == nil }
  var cashText: String { profile?.cash.map { $0.formatted() } ?? "—" }
  var moneyInputTitle: String { moneyOperation == .multiply ? "Multiplier" : "Amount" }
  var moneyPreview: String {
    guard let cash = profile?.cash, let amount = UInt64(amount) else {
      return "Enter a whole number."
    }
    do {
      return "New balance: \(try moneyOperation.result(current: cash, amount: amount).formatted())"
    } catch { return error.localizedDescription }
  }

  func load(_ profiles: [ProfileSummary]) {
    let previousCar = selectedCar
    self.profiles = profiles
    if !profiles.contains(where: { $0.id == selectedProfile }) {
      selectedProfile = profiles.first?.id ?? ""
    }
    selectProfile()
    if cars.contains(where: { $0.id == previousCar }) { selectedCar = previousCar }
  }

  func fingerprintForReplacement(of name: String) -> String? {
    guard let profile = profiles.first(where: { $0.id == name }), !profile.isRemoved else {
      return nil
    }
    return profile.fingerprint
  }

  private func selectProfile() {
    amount = profile?.cash.map(String.init) ?? "0"
    selectedCar = cars.first?.id ?? 0
    selectedBackup = backupNames.first ?? ""
  }

  private func loadCar() {
    levels = car?.levels ?? []
    junkman = car?.junkman ?? 0
    heat = car.map { String($0.heat) } ?? "1"
    bounty = car.map { String($0.bounty) } ?? "0"
  }

  func partLevels(_ index: Int) -> [UInt32] {
    guard let caps = car?.limits, caps.indices.contains(index) else { return [] }
    return Array(0...caps[index])
  }

  func partBinding(_ index: Int) -> Binding<UInt32> {
    Binding(
      get: { self.levels.indices.contains(index) ? self.levels[index] : 0 },
      set: {
        if self.levels.indices.contains(index) { self.levels[index] = $0 }
      })
  }

  func junkmanBinding(_ index: Int) -> Binding<Bool> {
    Binding(
      get: { self.junkman & (1 << index) != 0 },
      set: {
        if $0 { self.junkman |= 1 << index } else { self.junkman &= ~(1 << index) }
      })
  }

  func moneyRequest() throws(LauncherError) -> SaveRequest {
    guard let profile, let cash = profile.cash, let amount = UInt64(amount) else {
      throw .operation("Select a valid profile and enter a whole number.")
    }
    _ = try moneyOperation.result(current: cash, amount: amount)
    return .cheat(
      profile: profile.id, expected: profile.fingerprint,
      action: .money(operation: moneyOperation, amount: amount))
  }

  func carRequest() throws(LauncherError) -> SaveRequest {
    guard let profile, let car, let heat = Float(heat), let bounty = UInt32(bounty) else {
      throw .operation("Select a car and enter valid heat and bounty values.")
    }
    return .cheat(
      profile: profile.id, expected: profile.fingerprint,
      action: .car(car: car.id, levels: levels, junkman: junkman, heat: heat, bounty: bounty))
  }

  func duplicateRequest() throws(LauncherError) -> SaveRequest {
    guard let profile, let car, let count = Int(copies), (1...25).contains(count) else {
      throw .operation("Select a car and between 1 and 25 copies.")
    }
    return .cheat(
      profile: profile.id, expected: profile.fingerprint,
      action: .duplicate(car: car.id, count: count))
  }

  func addCarRequest() throws(LauncherError) -> SaveRequest {
    guard let profile, canEdit, CarModel.all[newCarSignature] != nil,
      let count = Int(newCarCount), (1...25).contains(count), cars.count + count <= 25
    else {
      throw .operation(
        "Select a model and a quantity that fits the selected career's 25-car garage.")
    }
    return .cheat(
      profile: profile.id, expected: profile.fingerprint,
      action: .addCar(signature: newCarSignature, count: count))
  }

  func createRequest() throws(LauncherError) -> SaveRequest {
    guard canCreateProfile else {
      throw .operation("Choose an unused name of 1–16 ASCII characters.")
    }
    return .create(profile: newProfileName)
  }

  func removeRequest() throws(LauncherError) -> SaveRequest {
    guard let profile, hasLiveProfile else { throw .operation("Select a saved profile first.") }
    return .remove(profile: profile.id, expected: profile.fingerprint)
  }

  func backupRequest() throws(LauncherError) -> SaveRequest {
    guard let profile else { throw .operation("Select a profile first.") }
    return .backup(profile: profile.id, expected: profile.fingerprint)
  }

  func restoreRequest() throws(LauncherError) -> SaveRequest {
    guard let profile, backupNames.contains(selectedBackup) else {
      throw .operation("Select a backup first.")
    }
    return .restore(
      profile: profile.id, name: selectedBackup,
      expected: profile.isRemoved ? nil : profile.fingerprint)
  }
}

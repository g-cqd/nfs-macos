import Foundation
import Testing

@testable import HubCore

@Suite struct GameLauncherTests {
  private func makeApp(in folder: URL, named name: String) throws -> URL {
    let game = folder.appendingPathComponent("\(name)/Contents/Resources/Game", isDirectory: true)
    try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
    return game
  }

  @Test func findsTheAppThatOwnsABundledGame() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let game = try makeApp(in: folder, named: "Test Game.app")
    let entry = CatalogEntry(id: "test", title: "Test", source: .bundle, root: game)
    let app = try #require(GameLauncher.wrappedApp(for: entry))
    #expect(app.lastPathComponent == "Test Game.app")
  }

  @Test func refusesOtherSourcesAndOddLayouts() throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let game = try makeApp(in: folder, named: "Test Game.app")
    #expect(
      GameLauncher.wrappedApp(for: CatalogEntry(id: "s", title: "S", source: .steam, root: game))
        == nil)
    let notAnApp = try makeApp(in: folder, named: "Plain Folder")
    #expect(
      GameLauncher.wrappedApp(
        for: CatalogEntry(id: "p", title: "P", source: .bundle, root: notAnApp)) == nil)
    let elsewhere = folder.appendingPathComponent("Other", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    #expect(
      GameLauncher.wrappedApp(
        for: CatalogEntry(id: "o", title: "O", source: .bundle, root: elsewhere)) == nil)
  }
}

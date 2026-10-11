import Foundation
import Testing

@testable import LauncherCore

/// Refreshing a text-profile preset against the live display before a game starts.
struct TextProfileRefreshTests {
  private let preset = TextProfilePreset(
    name: "fullscreen", title: "Full Screen",
    values: [
      .init(key: "GstRender.FullscreenEnabled", value: "1"),
      .init(key: "GstRender.FullscreenRefreshRate", value: "{display.refresh.float}"),
      .init(key: "GstRender.ResolutionWidth", value: "{display.width}"),
      .init(key: "GstRender.ResolutionHeight", value: "{display.height}"),
      .init(key: "GstRender.ResolutionHertz", value: "{display.refresh}"),
    ], reason: "Not verified")
  private let display = TextProfilePreset.Display(width: 3024, height: 1964, refresh: 120)

  private func profile(_ text: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "profile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let url = folder.appendingPathComponent("PROF_SAVE_profile")
    try Data(text.utf8).write(to: url)
    return url
  }

  private func backups(of profile: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: profile.deletingLastPathComponent().path)
      .filter { $0.hasPrefix("PROF_SAVE_profile.bak-") }.sorted()
  }

  @Test
  func `placeholders resolve to the display, including the six-decimal refresh`() throws {
    try preset.validate()
    let values = Dictionary(
      uniqueKeysWithValues: preset.resolved(for: display).map { ($0.key, $0.value) })
    #expect(values["GstRender.FullscreenRefreshRate"] == "120.000000")
    #expect(values["GstRender.ResolutionHertz"] == "120")
    #expect(values["GstRender.ResolutionWidth"] == "3024")
    #expect(values["GstRender.ResolutionHeight"] == "1964")
    #expect(values["GstRender.FullscreenEnabled"] == "1")
  }

  @Test
  func `only the lines that differ change, and CRLF endings stay`() throws {
    let text =
      "GstRender.FullscreenEnabled 1\r\nGstRender.FullscreenRefreshRate 60.000000\r\nGstGame.Other 7\r\nGstRender.ResolutionWidth 3024\r\nGstRender.ResolutionHeight 1964\r\nGstRender.ResolutionHertz 60\r\n"
    let url = try profile(text)
    let result = try preset.refresh(
      profile: url, display: display, gameIsRunning: false, stamp: "20260101-000001")
    guard case .applied(let backup, let lines, let missing) = result else {
      Issue.record("expected the file to change")
      return
    }
    #expect(backup == "PROF_SAVE_profile.bak-20260101-000001")
    #expect(missing.isEmpty)
    #expect(lines.contains("GstRender.ResolutionHertz 120"))
    #expect(
      try String(contentsOf: url, encoding: .utf8)
        == "GstRender.FullscreenEnabled 1\r\nGstRender.FullscreenRefreshRate 120.000000\r\nGstGame.Other 7\r\nGstRender.ResolutionWidth 3024\r\nGstRender.ResolutionHeight 1964\r\nGstRender.ResolutionHertz 120\r\n"
    )
    #expect(
      try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent(backup))
        == text)
  }

  @Test
  func `a profile that already matches is not written and gets no backup`() throws {
    let text =
      "GstRender.FullscreenEnabled 1\nGstRender.FullscreenRefreshRate 120.000000\nGstRender.ResolutionWidth 3024\nGstRender.ResolutionHeight 1964\nGstRender.ResolutionHertz 120\n"
    let url = try profile(text)
    let before = try url.resourceValues(forKeys: [.contentModificationDateKey])
      .contentModificationDate
    let result = try preset.refresh(
      profile: url, display: display, gameIsRunning: false, stamp: "20260101-000001")
    #expect(result == .unchanged(missing: []))
    #expect(try backups(of: url).isEmpty)
    #expect(
      try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        == before)
  }

  @Test
  func `keys the profile lacks are reported and not added`() throws {
    let url = try profile("GstRender.FullscreenEnabled 0\nGstGame.Other 7\n")
    let result = try preset.refresh(
      profile: url, display: display, gameIsRunning: false, stamp: "20260101-000001")
    guard case .applied(_, _, let missing) = result else {
      Issue.record("expected the file to change")
      return
    }
    #expect(missing.count == 4)
    #expect(missing.contains("GstRender.ResolutionWidth"))
    #expect(
      try String(contentsOf: url, encoding: .utf8)
        == "GstRender.FullscreenEnabled 1\nGstGame.Other 7\n")
  }

  @Test
  func `only the newest five backups are kept`() throws {
    let url = try profile("GstRender.FullscreenEnabled 0\n")
    for day in 1...7 {
      try Data().write(
        to: url.deletingLastPathComponent().appendingPathComponent(
          "PROF_SAVE_profile.bak-2026010\(day)-000000"))
    }
    _ = try preset.refresh(
      profile: url, display: display, gameIsRunning: false, stamp: "20260110-000000")
    #expect(
      try backups(of: url) == [
        "PROF_SAVE_profile.bak-20260104-000000", "PROF_SAVE_profile.bak-20260105-000000",
        "PROF_SAVE_profile.bak-20260106-000000", "PROF_SAVE_profile.bak-20260107-000000",
        "PROF_SAVE_profile.bak-20260110-000000",
      ])
  }

  @Test
  func `nothing is touched without a profile or while the game runs`() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "profile-\(UUID().uuidString)")
    let missing = folder.appendingPathComponent("PROF_SAVE_profile")
    #expect(
      try preset.refresh(profile: missing, display: display, gameIsRunning: false, stamp: "s")
        == .noProfile)
    let url = try profile("GstRender.FullscreenEnabled 0\n")
    #expect(
      try preset.refresh(profile: url, display: display, gameIsRunning: true, stamp: "s")
        == .gameRunning)
    #expect(try String(contentsOf: url, encoding: .utf8) == "GstRender.FullscreenEnabled 0\n")
    #expect(try backups(of: url).isEmpty)
  }
}

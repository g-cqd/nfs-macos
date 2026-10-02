import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

/// A bundled app creates its own Windows folder, so the player installs the EA app and signs in
/// from this app. These cover what the starter must know at each of those steps.
struct NFS2015OwnedFolderTests {
  private let plan = SyntheticPrefix.plan

  /// The game is seeded; nothing else has happened yet.
  private func seededOnly() throws -> SyntheticPrefix {
    let prefix = try SyntheticPrefix()
    try prefix.file("Program Files/EA Games/Need for Speed/NFS16.exe")
    try prefix.directory("users/Player")
    return prefix
  }

  private func installClient(in prefix: SyntheticPrefix, version: String = "13.796.0.6309") throws {
    let client = "Program Files/Electronic Arts/EA Desktop/\(version)/EA Desktop"
    try prefix.file(client + "/EADesktop.exe")
    try prefix.file(client + "/EALauncher.exe")
  }

  @Test
  func `asks for the EA app installer while the game is seeded and the client is not`() throws {
    let prefix = try seededOnly()
    defer { prefix.remove() }
    let readiness = try NFS2015Locator.resolve(prefix: prefix.root, plan: plan)
    #expect(readiness == .clientMissing("EA app"))
    #expect(readiness.setup == .installClient)
    let message = try #require(readiness.ownedMessage)
    #expect(message.contains("Install EA App"))
    #expect(message.contains("ea.com") && message.contains("Denuvo"))
    #expect(try NFS2015Locator.client(prefix: prefix.root, plan: plan) == nil)
  }

  @Test
  func `finds the installed client before anyone has signed in to it`() throws {
    let prefix = try seededOnly()
    defer { prefix.remove() }
    try installClient(in: prefix)
    let readiness = try NFS2015Locator.resolve(prefix: prefix.root, plan: plan)
    #expect(readiness == .notSignedIn("EA app"))
    #expect(readiness.setup == .signIn)
    #expect(try #require(readiness.ownedMessage).contains("Open EA App"))
    let client = try #require(try NFS2015Locator.client(prefix: prefix.root, plan: plan))
    #expect(client.version == "13.796.0.6309")
    #expect(client.executable.lastPathComponent == "EADesktop.exe")
    #expect(client.launcher.lastPathComponent == "EALauncher.exe")
    #expect(
      try NFS2015Install.windowsPath(of: client.executable, in: prefix.root)
        == #"C:\Program Files\Electronic Arts\EA Desktop\13.796.0.6309\EA Desktop\EADesktop.exe"#)
  }

  @Test
  func `uses the newest client folder and needs both of its programs`() throws {
    let prefix = try seededOnly()
    defer { prefix.remove() }
    try installClient(in: prefix, version: "13.700.0.1")
    try prefix.file("Program Files/Electronic Arts/EA Desktop/13.800.0.1/EA Desktop/EADesktop.exe")
    // The newest folder has the client but not its launcher stub: the install is incomplete.
    #expect(try NFS2015Locator.client(prefix: prefix.root, plan: plan) == nil)
    #expect(
      try NFS2015Locator.resolve(prefix: prefix.root, plan: plan) == .clientIncomplete("EA app"))
    #expect(
      try NFS2015Locator.resolve(prefix: prefix.root, plan: plan).setup == .installClient)
  }

  @Test
  func `needs nothing more once the client is installed and signed in`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let readiness = try NFS2015Locator.resolve(prefix: prefix.root, plan: plan)
    #expect(readiness.install != nil)
    #expect(readiness.setup == nil)
    #expect(readiness.ownedMessage == nil)
  }

  @Test
  func `says what to do when the seeded game itself has gone missing`() throws {
    let prefix = try SyntheticPrefix()
    defer { prefix.remove() }
    let readiness = try NFS2015Locator.resolve(prefix: prefix.root, plan: plan)
    #expect(readiness == .gameMissing)
    #expect(readiness.setup == nil)
    #expect(try #require(readiness.ownedMessage).contains("NFS2015Mac"))
  }

  @Test
  func `never tells a player of a bundled app to choose a Windows folder`() {
    let readiness: [NFS2015Readiness] = [
      .noInstallationChosen, .notAWindowsFolder, .gameMissing, .clientMissing("EA app"),
      .clientIncomplete("EA app"), .notSignedIn("EA app"),
    ]
    for item in readiness {
      let message = item.ownedMessage ?? ""
      #expect(!message.isEmpty)
      #expect(!message.localizedCaseInsensitiveContains("choose the windows folder"), "\(item)")
      #expect(!message.localizedCaseInsensitiveContains("choose the folder again"), "\(item)")
    }
  }

  @Test
  func `refuses a guest path outside the prefix`() throws {
    let prefix = try SyntheticPrefix()
    defer { prefix.remove() }
    #expect(throws: LauncherError.self) {
      try NFS2015Install.windowsPath(
        of: URL(fileURLWithPath: "/etc/hosts"), in: prefix.root)
    }
  }

  @Test
  func `keeps the starter's state readable across versions that lack the new fields`() throws {
    let current = NFS2015Snapshot(
      blocker: "Install", clientVersion: "13.796.0.6309", installedAt: "/prefix",
      hasOptionsFile: false, ownsWindowsFolder: true, setup: .installClient)
    let decoded = try JSONDecoder().decode(
      NFS2015Snapshot.self, from: try JSONEncoder().encode(current))
    #expect(decoded == current)
    #expect(decoded.setup == .installClient && decoded.ownsWindowsFolder == true)
    let legacy = try JSONEncoder().encode(
      NFS2015Snapshot(blocker: "Open the EA app", installedAt: "/Windows"))
    var object = try #require(try JSONSerialization.jsonObject(with: legacy) as? [String: Any])
    object["ownsWindowsFolder"] = nil
    object["setup"] = nil
    let old = try JSONDecoder().decode(
      NFS2015Snapshot.self, from: try JSONSerialization.data(withJSONObject: object))
    #expect(old.ownsWindowsFolder == nil && old.setup == nil)
    #expect(old.installedAt == "/Windows")
  }
}

struct ClientInstallerTests {
  private func installer(
    named name: String = "EAappInstaller.exe", header: String = "MZ", size: Int = 1_000_001
  ) throws -> (URL, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var bytes = Data(header.utf8)
    bytes.append(Data(count: max(0, size - bytes.count)))
    let url = root.appendingPathComponent(name)
    try bytes.write(to: url)
    return (root, url)
  }

  @Test
  func `accepts a Windows program of a plausible size`() throws {
    let (root, url) = try installer()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(try ClientInstaller.validate(url) == url.standardizedFileURL)
    let upper = root.appendingPathComponent("Setup.EXE")
    try FileManager.default.copyItem(at: url, to: upper)
    #expect(try ClientInstaller.validate(upper).lastPathComponent == "Setup.EXE")
  }

  @Test(arguments: ["installer.msi", "installer.exe.txt", "installer", "installer.dmg"])
  func `refuses a file that is not named like a Windows program`(name: String) throws {
    let (root, url) = try installer(named: name)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: LauncherError.self) { try ClientInstaller.validate(url) }
  }

  @Test
  func `refuses a file that is not a Windows program, or is implausibly small`() throws {
    let (rootA, notProgram) = try installer(header: "#!/bin/sh")
    let (rootB, tiny) = try installer(size: 100)
    defer {
      try? FileManager.default.removeItem(at: rootA)
      try? FileManager.default.removeItem(at: rootB)
    }
    #expect(throws: LauncherError.self) { try ClientInstaller.validate(notProgram) }
    #expect(throws: LauncherError.self) { try ClientInstaller.validate(tiny) }
  }

  @Test
  func `refuses a folder, a missing file and a link`() throws {
    let (root, url) = try installer()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Setup.exe", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(throws: LauncherError.self) { try ClientInstaller.validate(folder) }
    #expect(throws: LauncherError.self) {
      try ClientInstaller.validate(root.appendingPathComponent("absent.exe"))
    }
    let link = root.appendingPathComponent("Link.exe")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    #expect(throws: LauncherError.self) { try ClientInstaller.validate(link) }
  }
}

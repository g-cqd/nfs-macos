import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

struct NFS2015InstallTests {
  @Test
  func `recognises a complete installation and its client version`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let readiness = try NFS2015Locator.resolve(
      prefix: prefix.root, plan: SyntheticPrefix.plan)
    let install = try #require(readiness.install)
    #expect(readiness.message == nil)
    #expect(install.clientVersion == "13.796.0.6309")
    #expect(install.executable.lastPathComponent == "NFS16.exe")
    #expect(install.userProfile.lastPathComponent == "crossover")
    #expect(
      try install.windowsPath(of: install.client)
        == #"C:\Program Files\Electronic Arts\EA Desktop\13.796.0.6309\EA Desktop\EADesktop.exe"#)
  }

  @Test
  func `prefers the newest client version folder`() throws {
    let prefix = try SyntheticPrefix.complete(version: "13.700.0.1")
    defer { prefix.remove() }
    let newer = "Program Files/Electronic Arts/EA Desktop/13.796.0.6309/EA Desktop"
    try prefix.file(newer + "/EADesktop.exe")
    try prefix.file(newer + "/EALauncher.exe")
    let install = try #require(
      try NFS2015Locator.resolve(prefix: prefix.root, plan: SyntheticPrefix.plan).install)
    #expect(install.clientVersion == "13.796.0.6309")
  }

  @Test
  func `resolves installation folders whose case differs from the recipe`() throws {
    let prefix = try SyntheticPrefix()
    defer { prefix.remove() }
    try prefix.file("program files/ea games/NEED FOR SPEED/nfs16.exe")
    let client = "program files/electronic arts/ea desktop/13.796.0.6309/ea desktop"
    try prefix.file(client + "/eadesktop.exe")
    try prefix.file(client + "/ealauncher.exe")
    try prefix.directory("Users/crossover/appdata/local/electronic arts/ea desktop/logs")
    let readiness = try NFS2015Locator.resolve(prefix: prefix.root, plan: SyntheticPrefix.plan)
    #expect(readiness.install != nil)
  }

  @Test
  func `reports a folder that is not a Windows installation`() throws {
    let prefix = try SyntheticPrefix()
    defer { prefix.remove() }
    let empty = prefix.root.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let readiness = try NFS2015Locator.resolve(prefix: empty, plan: SyntheticPrefix.plan)
    #expect(readiness == .notAWindowsFolder)
    #expect(readiness.message?.contains("drive_c") == true)
  }

  @Test
  func `reports the game as missing before it is installed`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    try FileManager.default.removeItem(
      at: prefix.driveC.appendingPathComponent("Program Files/EA Games/Need for Speed/NFS16.exe"))
    let readiness = try NFS2015Locator.resolve(prefix: prefix.root, plan: SyntheticPrefix.plan)
    #expect(readiness == .gameMissing)
    #expect(readiness.message?.contains("EA app") == true)
  }

  @Test
  func `names Denuvo and the client when the client is absent`() throws {
    let prefix = try SyntheticPrefix()
    defer { prefix.remove() }
    try prefix.file("Program Files/EA Games/Need for Speed/NFS16.exe")
    let readiness = try NFS2015Locator.resolve(prefix: prefix.root, plan: SyntheticPrefix.plan)
    #expect(readiness == .clientMissing("EA app"))
    let message = try #require(readiness.message)
    #expect(message.contains("Denuvo"))
    #expect(message.contains("EA app"))
  }

  @Test
  func `reports an incomplete client installation`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    try FileManager.default.removeItem(
      at: prefix.driveC.appendingPathComponent(
        "Program Files/Electronic Arts/EA Desktop/13.796.0.6309/EA Desktop/EALauncher.exe"))
    let readiness = try NFS2015Locator.resolve(prefix: prefix.root, plan: SyntheticPrefix.plan)
    #expect(readiness == .clientIncomplete("EA app"))
  }

  @Test
  func `asks the player to sign in when the client has no account folder`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    try FileManager.default.removeItem(
      at: prefix.driveC.appendingPathComponent("users/crossover/AppData"))
    let readiness = try NFS2015Locator.resolve(prefix: prefix.root, plan: SyntheticPrefix.plan)
    #expect(readiness == .notSignedIn("EA app"))
    let message = try #require(readiness.message)
    #expect(message.contains("sign in"))
    #expect(message.contains("never stores"))
  }

  @Test
  func `refuses a linked installation folder`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let games = prefix.driveC.appendingPathComponent("Program Files/EA Games")
    try FileManager.default.removeItem(at: games)
    try FileManager.default.createSymbolicLink(
      atPath: games.path, withDestinationPath: prefix.root.path)
    #expect(throws: LauncherError.self) {
      try NFS2015Locator.resolve(prefix: prefix.root, plan: SyntheticPrefix.plan)
    }
  }

  @Test
  func `records a recognised folder and reads it back`() throws {
    let prefix = try SyntheticPrefix.complete()
    defer { prefix.remove() }
    let support = prefix.root.appendingPathComponent("Player")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let reference = InstallReference(support: support, plan: SyntheticPrefix.plan)
    #expect(try reference.readiness() == .noInstallationChosen)
    let adopted = try reference.adopt(prefix.root, transaction: FileTransaction(root: support))
    #expect(adopted.install != nil)
    let stored = try #require(try reference.load())
    #expect(stored.clientVersion == "13.796.0.6309")
    #expect(try reference.readiness().install != nil)
  }

  @Test
  func `refuses to record a folder without the client`() throws {
    let prefix = try SyntheticPrefix()
    defer { prefix.remove() }
    try prefix.file("Program Files/EA Games/Need for Speed/NFS16.exe")
    let support = prefix.root.appendingPathComponent("Player")
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    let reference = InstallReference(support: support, plan: SyntheticPrefix.plan)
    #expect(
      try reference.adopt(prefix.root, transaction: FileTransaction(root: support))
        == .clientMissing("EA app"))
    #expect(try reference.load() == nil)
  }
}

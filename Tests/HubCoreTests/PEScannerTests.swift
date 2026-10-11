import Foundation
import Testing

@testable import HubCore

/// Creates a temporary directory with a UUID suffix, cleaned up in defer.
private func makeTempRoot(tag: String) -> URL {
  let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
    "\(tag)-\(UUID().uuidString)", isDirectory: true
  )
  try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: false)
  return tempRoot
}

@Suite struct PEScannerTests {
  // MARK: - Basic parsing tests

  @Test func parsesI386GuiImports() throws {
    let pe = try PEScanner.parse(
      PEFixture.make(
        machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
        imports: ["d3d9.dll", "dsound.dll"],
        delayImports: [],
        delayUsesVA: false
      )
    )
    #expect(pe.machine == "i386")
    #expect(pe.pe32Plus == false)
    #expect(pe.isDLL == false)
    #expect(pe.subsystem == "gui")
    #expect(pe.imports == ["d3d9.dll", "dsound.dll"])
    #expect(pe.delayImports.isEmpty)
  }

  @Test func parsesX86_64ConsoleWithDelayImportsRVA() throws {
    let pe = try PEScanner.parse(
      PEFixture.make(
        machine: 0x8664, pe32Plus: true, subsystem: 3, dll: false,
        imports: ["dxgi.dll", "d3d11.dll"],
        delayImports: ["steam_api64.dll"],
        delayUsesVA: false
      )
    )
    #expect(pe.machine == "x86_64")
    #expect(pe.pe32Plus == true)
    #expect(pe.subsystem == "console")
    #expect(pe.imports == ["d3d11.dll", "dxgi.dll"])
    #expect(pe.delayImports == ["steam_api64.dll"])
  }

  @Test func parsesX86_64ConsoleWithDelayImportsVA() throws {
    let pe = try PEScanner.parse(
      PEFixture.make(
        machine: 0x8664, pe32Plus: true, subsystem: 3, dll: false,
        imports: ["dxgi.dll", "d3d11.dll"],
        delayImports: ["steam_api64.dll"],
        delayUsesVA: true
      )
    )
    #expect(pe.machine == "x86_64")
    #expect(pe.pe32Plus == true)
    #expect(pe.subsystem == "console")
    #expect(pe.imports == ["d3d11.dll", "dxgi.dll"])
    #expect(pe.delayImports == ["steam_api64.dll"])
  }

  @Test func recognizesDLLFlag() throws {
    let pe = try PEScanner.parse(
      PEFixture.make(
        machine: 0x14c, pe32Plus: false, subsystem: 2, dll: true,
        imports: [],
        delayImports: [],
        delayUsesVA: false
      )
    )
    #expect(pe.isDLL == true)
  }

  @Test func returnsUnknownMachineAsHex() throws {
    let pe = try PEScanner.parse(
      PEFixture.make(
        machine: 0xaaaa, pe32Plus: false, subsystem: 2, dll: false,
        imports: [],
        delayImports: [],
        delayUsesVA: false
      )
    )
    #expect(pe.machine == "0xaaaa")
  }

  @Test func returnsUnknownSubsystemAsLabel() throws {
    let pe = try PEScanner.parse(
      PEFixture.make(
        machine: 0x14c, pe32Plus: false, subsystem: 99, dll: false,
        imports: [],
        delayImports: [],
        delayUsesVA: false
      )
    )
    #expect(pe.subsystem == "other:99")
  }

  @Test func recognizesARM64Machine() throws {
    let pe = try PEScanner.parse(
      PEFixture.make(
        machine: 0xaa64, pe32Plus: true, subsystem: 2, dll: false,
        imports: [],
        delayImports: [],
        delayUsesVA: false
      )
    )
    #expect(pe.machine == "arm64")
  }

  // MARK: - Robustness tests: truncation

  @Test func truncationNeverTraps() throws {
    let fullPE = PEFixture.make(
      machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
      imports: ["kernel32.dll"],
      delayImports: [],
      delayUsesVA: false
    )

    // sectionTableEnd = peOffset + 24 + 224 + 2*40
    let sectionTableEnd = PEFixture.peOffset + 24 + 224 + 2 * 40

    // For length in 0..<sectionTableEnd, expect throws
    for length in 0..<sectionTableEnd {
      #expect(throws: (any Error).self) { try PEScanner.parse(Array(fullPE.prefix(length))) }
    }

    // For the rest, call parse and ignore the result
    for length in sectionTableEnd..<fullPE.count {
      _ = try? PEScanner.parse(Array(fullPE.prefix(length)))
    }
  }

  // MARK: - Error cases

  @Test func rejectsInvalidElfanew() throws {
    var pe = PEFixture.make(
      machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
      imports: [],
      delayImports: [],
      delayUsesVA: false
    )
    // Set e_lfanew to 0xFFFFFFFF
    pe[0x3C] = 0xFF
    pe[0x3D] = 0xFF
    pe[0x3E] = 0xFF
    pe[0x3F] = 0xFF

    do { _ = try PEScanner.parse(pe); Issue.record("should have thrown"); return }
    catch { guard case let .invalid(msg)? = (error as? HubError) else { Issue.record("wrong error \(error)"); return }; #expect(msg.contains("e_lfanew")) }
  }

  @Test func rejectsZeroSections() throws {
    var pe = PEFixture.make(
      machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
      imports: [],
      delayImports: [],
      delayUsesVA: false
    )
    // Set numberOfSections to 0 at PEFixture.coffOffset + 2
    PEFixture.put16(&pe, PEFixture.coffOffset + 2, 0)

    do { _ = try PEScanner.parse(pe); Issue.record("should have thrown"); return }
    catch { guard case let .invalid(msg)? = (error as? HubError) else { Issue.record("wrong error \(error)"); return }; #expect(msg.contains("numberOfSections")) }
  }

  @Test func rejectsExcessiveSections() throws {
    var pe = PEFixture.make(
      machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
      imports: [],
      delayImports: [],
      delayUsesVA: false
    )
    // Set numberOfSections to 0xFFFF at PEFixture.coffOffset + 2
    PEFixture.put16(&pe, PEFixture.coffOffset + 2, 0xFFFF)

    do { _ = try PEScanner.parse(pe); Issue.record("should have thrown"); return }
    catch { guard case let .invalid(msg)? = (error as? HubError) else { Issue.record("wrong error \(error)"); return }; #expect(msg.contains("numberOfSections")) }
  }

  // MARK: - Import name validation

  @Test func rejectsNameWithoutNUL() throws {
    var pe = PEFixture.make(
      machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
      imports: ["a.dll"], delayImports: [], delayUsesVA: false)
    let at = try #require(PEFixture.offset(of: "a.dll", in: pe))
    for i in 0..<300 { pe[at + i] = 0x41 }
    do { _ = try PEScanner.parse(pe); Issue.record("should have thrown"); return }
    catch { guard case let .invalid(msg)? = (error as? HubError) else { Issue.record("wrong error \(error)"); return }; #expect(msg.contains("terminat")) }
  }

  @Test func rejectsNameRVAOutOfRange() throws {
    var pe = PEFixture.make(
      machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
      imports: ["a.dll"], delayImports: [], delayUsesVA: false)
    PEFixture.put32(&pe, PEFixture.rdataFileOffset + 12, 0xFFFF_FFFF)
    do { _ = try PEScanner.parse(pe); Issue.record("should have thrown"); return }
    catch { guard case let .invalid(msg)? = (error as? HubError) else { Issue.record("wrong error \(error)"); return }; #expect(msg.contains("unmappable")) }
  }

  @Test func acceptsMaxImportDescriptors() throws {
    let pe = try PEScanner.parse(
      PEFixture.make(
        machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
        imports: Array(repeating: "a.dll", count: 1024), delayImports: [], delayUsesVA: false)
    )
    #expect(!pe.imports.isEmpty)
  }

  @Test func rejectsExcessiveImportDescriptors() throws {
    let pe = PEFixture.make(
      machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
      imports: Array(repeating: "a.dll", count: 1025), delayImports: [], delayUsesVA: false)
    do {
      _ = try PEScanner.parse(pe)
      Issue.record("should have thrown")
      return
    } catch {
      guard case let .invalid(msg)? = (error as? HubError) else {
        Issue.record("wrong error \(error)")
        return
      }
      #expect(msg.contains("too many"))
    }
  }

  @Test func acceptsMaxDelayImportDescriptors() throws {
    let pe = try PEScanner.parse(
      PEFixture.make(
        machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
        imports: [], delayImports: Array(repeating: "a.dll", count: 1024), delayUsesVA: false)
    )
    #expect(!pe.delayImports.isEmpty)
  }

  @Test func rejectsExcessiveDelayImportDescriptors() throws {
    let pe = PEFixture.make(
      machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
      imports: [], delayImports: Array(repeating: "a.dll", count: 1025), delayUsesVA: false)
    do {
      _ = try PEScanner.parse(pe)
      Issue.record("should have thrown")
      return
    } catch {
      guard case let .invalid(msg)? = (error as? HubError) else {
        Issue.record("wrong error \(error)")
        return
      }
      #expect(msg.contains("too many"))
    }
  }

  @Test func rejectsEmptyImportName() throws {
    var pe = PEFixture.make(
      machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
      imports: ["a.dll"], delayImports: [], delayUsesVA: false)
    let at = try #require(PEFixture.offset(of: "a.dll", in: pe))
    pe[at] = 0  // NUL byte at the name offset
    do { _ = try PEScanner.parse(pe); Issue.record("should have thrown"); return }
    catch { guard case let .invalid(msg)? = (error as? HubError) else { Issue.record("wrong error \(error)"); return }; #expect(msg.contains("empty DLL name")) }
  }

  @Test func rejectsNonASCIIImportName() throws {
    var pe = PEFixture.make(
      machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
      imports: ["a.dll"], delayImports: [], delayUsesVA: false)
    let at = try #require(PEFixture.offset(of: "a.dll", in: pe))
    pe[at] = 0xE9
    do { _ = try PEScanner.parse(pe); Issue.record("should have thrown"); return }
    catch { guard case let .invalid(msg)? = (error as? HubError) else { Issue.record("wrong error \(error)"); return }; #expect(msg.contains("non-ASCII") || msg.contains("ASCII")) }
  }

  @Test func rejectsUnmappableDelayImportName() throws {
    var pe = PEFixture.make(
      machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
      imports: [], delayImports: ["a.dll"], delayUsesVA: false)
    // Delay table follows the (empty) import table at the start of .rdata; DllNameRVA is at +4.
    PEFixture.put32(&pe, PEFixture.rdataFileOffset + 4, 0xFFFF_FFFF)
    do { _ = try PEScanner.parse(pe); Issue.record("should have thrown"); return }
    catch { guard case let .invalid(msg)? = (error as? HubError) else { Issue.record("wrong error \(error)"); return }; #expect(msg.contains("unmappable")) }
  }

  @Test func delayVABelowImageBase() throws {
    var pe = PEFixture.make(
      machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
      imports: [], delayImports: ["a.dll"], delayUsesVA: true)
    // Patch DllNameRVA at rdataFileOffset + 4 to 0x1000 (< ImageBase 0x400000)
    PEFixture.put32(&pe, PEFixture.rdataFileOffset + 4, 0x1000)
    let result = try PEScanner.parse(pe)
    // When delay import VA is below ImageBase, it should be skipped
    #expect(result.delayImports.isEmpty)
  }

  // MARK: - Imports are normalized

  @Test func importsAreLowercasedAndSorted() throws {
    let pe = try PEScanner.parse(
      PEFixture.make(
        machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
        imports: ["Kernel32.dll", "ADVAPI32.DLL", "User32.dll"],
        delayImports: [],
        delayUsesVA: false
      )
    )
    #expect(pe.imports == ["advapi32.dll", "kernel32.dll", "user32.dll"])
  }

  @Test func deduplicatesImports() throws {
    let pe = try PEScanner.parse(
      PEFixture.make(
        machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
        imports: ["kernel32.dll", "kernel32.dll", "user32.dll"],
        delayImports: [],
        delayUsesVA: false
      )
    )
    // After dedup, should have 2 imports
    #expect(pe.imports == ["kernel32.dll", "user32.dll"])
  }

  @Test func includesTimestamp() throws {
    let pe = try PEScanner.parse(
      PEFixture.make(
        machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
        imports: [],
        delayImports: [],
        delayUsesVA: false
      )
    )
    #expect(pe.timestamp == 0x12345678)
  }

  @Test func includesSections() throws {
    let pe = try PEScanner.parse(
      PEFixture.make(
        machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
        imports: [],
        delayImports: [],
        delayUsesVA: false
      )
    )
    #expect(pe.sections.count == 2)
    #expect(pe.sections[0] == ".rdata")
    #expect(pe.sections[1] == ".text")
  }
}

@Suite struct FolderMarkersTests {
  @Test func scansKnownMarkers() throws {
    let root = makeTempRoot(tag: "markers_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    // Create steam marker
    let bin = root.appendingPathComponent("Bin32", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try "".write(toFile: bin.appendingPathComponent("steam_api.dll").path, atomically: true, encoding: .utf8)

    // Create EA marker in subdirectory
    let installerDir = root.appendingPathComponent("__INSTALLER", isDirectory: true)
    try FileManager.default.createDirectory(at: installerDir, withIntermediateDirectories: true)
    try "".write(toFile: installerDir.appendingPathComponent("InstallerData.xml").path, atomically: true, encoding: .utf8)

    let found = FolderMarkers.scan(root: root)
    #expect(found.contains("steam_api.dll"))
    #expect(found.contains("__Installer/installerdata.xml"))
  }

  @Test func skipsSymlinksFixture() throws {
    let root = makeTempRoot(tag: "symlink_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    // Create a real directory with a marker
    let realDir = root.appendingPathComponent("real_egstore", isDirectory: true)
    try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)

    // Create a symlink with the marker name (should NOT match)
    let symlinkPath = root.appendingPathComponent(".egstore").path
    try? FileManager.default.removeItem(atPath: symlinkPath)
    try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: realDir.path)

    // Also add steam_appid.txt to match the fixture requirement
    try "".write(toFile: root.appendingPathComponent("steam_appid.txt").path, atomically: true, encoding: .utf8)

    let found = FolderMarkers.scan(root: root)
    // Should find only steam_appid.txt (symlink should NOT be matched)
    #expect(found == ["steam_appid.txt"])
  }

  @Test func caseInsensitiveMatching() throws {
    let root = makeTempRoot(tag: "case_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    // Create Steam marker with different case
    try "".write(toFile: root.appendingPathComponent("STEAM_API.DLL").path, atomically: true, encoding: .utf8)

    let found = FolderMarkers.scan(root: root)
    // Should match despite case difference
    #expect(found.contains("steam_api.dll"))
  }

  @Test func skipsSymlinkedSubdirectory() throws {
    let root = makeTempRoot(tag: "symlink_subdir_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    // Create a directory outside root with a marker inside
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true
    )
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }

    // Add steam_appid.txt to the outside directory
    try "".write(toFile: outside.appendingPathComponent("steam_appid.txt").path, atomically: true, encoding: .utf8)

    // Create a symlink to the outside dir inside root
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("linked").path,
      withDestinationPath: outside.path
    )

    let found = FolderMarkers.scan(root: root)
    // Symlinked subdirectory should not be matched
    #expect(found.isEmpty)
  }
}

@Suite struct ExecutableFinderTests {
  @Test func findsExecutables() throws {
    let root = makeTempRoot(tag: "finder_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    // Create some executables
    try Data([0x4D, 0x5A] + [UInt8](repeating: 0, count: 100)).write(to: root.appendingPathComponent("game.exe"))
    try Data([0x4D, 0x5A] + [UInt8](repeating: 0, count: 200)).write(to: root.appendingPathComponent("player.exe"))

    let found = ExecutableFinder.candidates(root: root)
    #expect(found.count == 2)
    #expect(found.contains { $0.lastPathComponent == "game.exe" })
    #expect(found.contains { $0.lastPathComponent == "player.exe" })
  }

  @Test func excludesInstallers() throws {
    let root = makeTempRoot(tag: "installer_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    // Create game executable
    try Data([0x4D, 0x5A] + [UInt8](repeating: 0, count: 1000)).write(to: root.appendingPathComponent("game.exe"))

    // Create installer executables (should be excluded)
    try Data([0x4D, 0x5A] + [UInt8](repeating: 0, count: 100)).write(to: root.appendingPathComponent("unins000.exe"))
    try Data([0x4D, 0x5A] + [UInt8](repeating: 0, count: 100)).write(to: root.appendingPathComponent("Setup.exe"))
    try Data([0x4D, 0x5A] + [UInt8](repeating: 0, count: 100)).write(to: root.appendingPathComponent("vcredist_x64.exe"))

    let found = ExecutableFinder.candidates(root: root)
    #expect(found.contains { $0.lastPathComponent == "game.exe" })
    #expect(!found.contains { $0.lastPathComponent == "unins000.exe" })
    #expect(!found.contains { $0.lastPathComponent == "Setup.exe" })
    #expect(!found.contains { $0.lastPathComponent == "vcredist_x64.exe" })
  }

  @Test func sortsByFileSizeDescending() throws {
    let root = makeTempRoot(tag: "size_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    // Create executables with different sizes
    try Data([UInt8](repeating: 0, count: 100)).write(to: root.appendingPathComponent("small.exe"))
    try Data([UInt8](repeating: 0, count: 1000)).write(to: root.appendingPathComponent("medium.exe"))
    try Data([UInt8](repeating: 0, count: 500)).write(to: root.appendingPathComponent("tiny.exe"))

    let found = ExecutableFinder.candidates(root: root)
    #expect(found.count == 3)
    #expect(found.map { $0.lastPathComponent } == ["medium.exe", "tiny.exe", "small.exe"])
    let sizes = found.map { url -> Int in
      (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
    for i in 0..<(sizes.count - 1) {
      #expect(sizes[i] >= sizes[i + 1])
    }
  }

  @Test func respectsDepthLimit() throws {
    let root = makeTempRoot(tag: "depth_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    // Create nested structure
    let level1 = root.appendingPathComponent("level1", isDirectory: true)
    let level2 = level1.appendingPathComponent("level2", isDirectory: true)
    let level3 = level2.appendingPathComponent("level3", isDirectory: true)
    let level4 = level3.appendingPathComponent("level4", isDirectory: true)

    try FileManager.default.createDirectory(at: level4, withIntermediateDirectories: true)

    // Create executables at each level
    try Data([UInt8](repeating: 0, count: 100)).write(to: root.appendingPathComponent("root.exe"))
    try Data([UInt8](repeating: 0, count: 100)).write(to: level1.appendingPathComponent("l1.exe"))
    try Data([UInt8](repeating: 0, count: 100)).write(to: level2.appendingPathComponent("l2.exe"))
    try Data([UInt8](repeating: 0, count: 100)).write(to: level3.appendingPathComponent("l3.exe"))
    try Data([UInt8](repeating: 0, count: 100)).write(to: level4.appendingPathComponent("l4.exe"))

    let found = ExecutableFinder.candidates(root: root)
    // Should find up to depth 3, so l3.exe but not l4.exe
    let names = found.map { $0.lastPathComponent }
    #expect(names.contains("root.exe"))
    #expect(names.contains("l1.exe"))
    #expect(names.contains("l2.exe"))
    #expect(names.contains("l3.exe"))
    #expect(!names.contains("l4.exe"))
  }

  @Test func skipsSymlinkedDirectories() throws {
    let root = makeTempRoot(tag: "symdir_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    // A directory outside root holding an exe, reachable only through a symlink inside root.
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "symdir_outside_\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data([UInt8](repeating: 0, count: 100)).write(to: outside.appendingPathComponent("hidden.exe"))
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("linked").path, withDestinationPath: outside.path)

    let realSubdir = root.appendingPathComponent("realsubdir", isDirectory: true)
    try FileManager.default.createDirectory(at: realSubdir, withIntermediateDirectories: true)
    try Data([UInt8](repeating: 0, count: 100)).write(to: realSubdir.appendingPathComponent("real.exe"))

    let names = ExecutableFinder.candidates(root: root).map { $0.lastPathComponent }
    #expect(names == ["real.exe"])
  }

  @Test func limitNegativeReturnsEmpty() throws {
    let root = makeTempRoot(tag: "limit_negative_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    try Data([0x4D, 0x5A] + [UInt8](repeating: 0, count: 100)).write(to: root.appendingPathComponent("game.exe"))
    let found = ExecutableFinder.candidates(root: root, limit: -1)
    #expect(found.isEmpty)
  }

  @Test func skipsSymlinkedFiles() throws {
    let root = makeTempRoot(tag: "symlink_file_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    // Create a real exe file outside root
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "symlink_outside_\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data([UInt8](repeating: 0, count: 100)).write(to: outside.appendingPathComponent("original.exe"))

    // Create a symlink to it inside root
    try FileManager.default.createSymbolicLink(
      atPath: root.appendingPathComponent("x.exe").path,
      withDestinationPath: outside.appendingPathComponent("original.exe").path
    )

    // Also create a real exe
    try Data([UInt8](repeating: 0, count: 200)).write(to: root.appendingPathComponent("real.exe"))

    let found = ExecutableFinder.candidates(root: root)
    let names = found.map { $0.lastPathComponent }
    #expect(names.contains("real.exe"))
    #expect(!names.contains("x.exe"))
  }

  @Test func findsUppercaseExtension() throws {
    let root = makeTempRoot(tag: "uppercase_ext_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    try Data([UInt8](repeating: 0, count: 100)).write(to: root.appendingPathComponent("game.EXE"))
    let found = ExecutableFinder.candidates(root: root)
    #expect(found.contains { $0.lastPathComponent == "game.EXE" })
  }

  @Test func breaksFileSizeTieByPath() throws {
    let root = makeTempRoot(tag: "tie_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    // Create two files with the same size
    let sameSize = [UInt8](repeating: 0, count: 100)
    try Data(sameSize).write(to: root.appendingPathComponent("zulu.exe"))
    try Data(sameSize).write(to: root.appendingPathComponent("alpha.exe"))

    let found = ExecutableFinder.candidates(root: root)
    #expect(found.count == 2)
    // When sizes are equal, should be sorted by path
    #expect(found[0].lastPathComponent == "alpha.exe")
    #expect(found[1].lastPathComponent == "zulu.exe")
  }

  @Test func findsGameExeWithManyTools() throws {
    let root = makeTempRoot(tag: "tools_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    // Create tool00.exe through tool63.exe (64 files, 10 bytes each)
    for i in 0..<64 {
      let toolName = String(format: "tool%02d.exe", i)
      try Data([UInt8](repeating: 0, count: 10)).write(to: root.appendingPathComponent(toolName))
    }
    // Create game.exe (10,000 bytes)
    try Data([UInt8](repeating: 0, count: 10_000)).write(to: root.appendingPathComponent("game.exe"))

    let found = ExecutableFinder.candidates(root: root)
    // Default limit is 64, so we should get 64 files (game.exe + 63 tool files)
    #expect(found.count == 64)
    #expect(found[0].lastPathComponent == "game.exe")
  }

  @Test func readsValidPEFromFile() throws {
    let root = makeTempRoot(tag: "valid_pe_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    let gameExePath = root.appendingPathComponent("game.exe")
    let pe = PEFixture.make(
      machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
      imports: ["kernel32.dll"],
      delayImports: [],
      delayUsesVA: false
    )
    try Data(pe).write(to: gameExePath)

    let result = try PEScanner.read(gameExePath)
    #expect(result.machine == "i386")
    #expect(result.imports.contains("kernel32.dll"))
  }

  @Test func readsSymlinkThrowsInvalid() throws {
    let root = makeTempRoot(tag: "symlink_read_test")
    defer {
      try? FileManager.default.removeItem(at: root)
    }

    let gameExePath = root.appendingPathComponent("game.exe")
    let linkPath = root.appendingPathComponent("link.exe")
    let pe = PEFixture.make(
      machine: 0x14c, pe32Plus: false, subsystem: 2, dll: false,
      imports: ["kernel32.dll"],
      delayImports: [],
      delayUsesVA: false
    )
    try Data(pe).write(to: gameExePath)
    try FileManager.default.createSymbolicLink(atPath: linkPath.path, withDestinationPath: gameExePath.path)

    do { _ = try PEScanner.read(linkPath); Issue.record("should have thrown"); return }
    catch { guard case let .invalid(msg)? = (error as? HubError) else { Issue.record("wrong error \(error)"); return }; #expect(msg.contains("not a regular file")) }
  }
}


import Darwin
import Foundation
import Testing
@testable import HubCore

// Pattern helper for matching HubError cases with payloads
private func isCase(_ e: any Error, _ match: (HubError) -> Bool) -> Bool {
  guard let hubError = e as? HubError else { return false }
  return match(hubError)
}

private func isUnsafePath(_ e: Error) -> Bool {
  guard let hubError = e as? HubError, case .unsafePath = hubError else { return false }
  return true
}

private func isInvalid(_ e: Error) -> Bool {
  guard let hubError = e as? HubError, case .invalid = hubError else { return false }
  return true
}

private func isVolumeMissing(_ e: Error, _ expectedPath: String? = nil) -> Bool {
  guard let hubError = e as? HubError else { return false }
  switch hubError {
  case .volumeMissing(let path):
    if let expectedPath = expectedPath {
      return path == expectedPath
    }
    return true
  default:
    return false
  }
}

@Suite struct SharedPrefixTests {
  // MARK: - Test 1: Direct prefix locate

  @Test func directPrefixLocate() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let prefixPath = tempDir.appendingPathComponent("Prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixPath)

    let prefix = try SharedPrefix.locate(prefixPath.path, allowedRoots: [tempDir])
    // Compare resolved paths because /var -> /private/var on macOS
    let resolvedPrefixPath = realPath(prefixPath.path)
    let resolvedActual = prefix.resolved.path
    #expect(resolvedActual == resolvedPrefixPath)
    #expect(prefix.hops.isEmpty)
  }

  // MARK: - Test 2: Symlink chain

  @Test func symlinkChain() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let link1 = tempDir.appendingPathComponent("link1")
    let link2 = tempDir.appendingPathComponent("link2")
    let realDir = tempDir.appendingPathComponent("Prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    try createPrefixStructure(at: realDir)

    // Create link chain: link1 -> link2 -> real
    try createSymlink(at: link1, to: "link2")
    try createSymlink(at: link2, to: realDir.path)

    let prefix = try SharedPrefix.locate(link1.path, allowedRoots: [tempDir])
    // Compare resolved paths because /var -> /private/var on macOS
    let resolvedRealPath = realPath(realDir.path)
    let resolvedActual = prefix.resolved.path
    #expect(resolvedActual == resolvedRealPath)
    #expect(prefix.hops.count == 2)
  }

  // MARK: - Test 3: Hop escaping allowed root

  @Test func hopEscapingRoot() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let linkPath = tempDir.appendingPathComponent("link")

    // Create a symlink that points outside the allowed root
    try createSymlink(at: linkPath, to: "/var")

    var errorThrown = false
    do {
      _ = try SharedPrefix.locate(linkPath.path, allowedRoots: [tempDir])
    } catch {
      errorThrown = isUnsafePath(error)
    }
    #expect(errorThrown)
  }

  // MARK: - Test 4: Symlink loop

  @Test func symlinkLoop() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let linkA = tempDir.appendingPathComponent("a")
    let linkB = tempDir.appendingPathComponent("b")

    // Create loop: a -> b -> a
    try createSymlink(at: linkA, to: linkB.path)
    try createSymlink(at: linkB, to: linkA.path)

    var errorThrown = false
    do {
      _ = try SharedPrefix.locate(linkA.path, allowedRoots: [tempDir])
    } catch {
      errorThrown = isUnsafePath(error)
    }
    #expect(errorThrown)
  }

  // MARK: - Test 5: Volume missing

  @Test func volumeMissing() throws {
    let missingVolumeUUID = UUID().uuidString
    let missingVolumePath = "/Volumes/HubTestMissing-\(missingVolumeUUID)/GameHub/Prefix"
    let expectedVolumePath = "/Volumes/HubTestMissing-\(missingVolumeUUID)"

    #expect { _ = try SharedPrefix.locate(missingVolumePath, allowedRoots: [URL(fileURLWithPath: "/tmp")]) } throws: { ($0 as? HubError) == .volumeMissing(expectedVolumePath) }

    // Verify nothing was created
    #expect(!FileManager.default.fileExists(atPath: missingVolumePath))
  }

  // MARK: - Test 5b: Volume missing in allowedRoots

  @Test func volumeMissingInAllowedRoots() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let prefixPath = tempDir.appendingPathComponent("Prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixPath)

    // allowedRoots with missing volume
    let missingVolumeUUID = UUID().uuidString
    let missingVolumeRoot = "/Volumes/HubTestMissing-\(missingVolumeUUID)/root"
    let expectedVolumePath = "/Volumes/HubTestMissing-\(missingVolumeUUID)"

    #expect { _ = try SharedPrefix.locate(prefixPath.path, allowedRoots: [URL(fileURLWithPath: missingVolumeRoot)]) } throws: { ($0 as? HubError) == .volumeMissing(expectedVolumePath) }
  }

  // MARK: - Test 6: Missing system.reg

  @Test func missingsystemReg() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let prefixPath = tempDir.appendingPathComponent("Prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)

    // Create minimal structure without system.reg
    try FileManager.default.createDirectory(at: prefixPath.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: prefixPath.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
    let userRegPath = prefixPath.appendingPathComponent("user.reg")
    try "".write(to: userRegPath, atomically: true, encoding: .utf8)

    var errorThrown = false
    do {
      _ = try SharedPrefix.locate(prefixPath.path, allowedRoots: [tempDir])
    } catch {
      errorThrown = isCase(error, { if case .invalid = $0 { return true } else { return false } })
    }
    #expect(errorThrown)
  }

  // MARK: - Test 7: drive_c as symlink

  @Test func driveCAsSymlink() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let prefixPath = tempDir.appendingPathComponent("Prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixPath)

    // Make drive_c a symlink instead of directory
    let driveCPath = prefixPath.appendingPathComponent("drive_c")
    try FileManager.default.removeItem(at: driveCPath)
    try createSymlink(at: driveCPath, to: ".")

    var errorThrown = false
    do {
      _ = try SharedPrefix.locate(prefixPath.path, allowedRoots: [tempDir])
    } catch {
      errorThrown = isCase(error, { if case .invalid = $0 { return true } else { return false } })
    }
    #expect(errorThrown)
  }

  // MARK: - Test 8: Problems detection

  @Test func problemsDetection() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let prefixPath = tempDir.appendingPathComponent("Prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixPath)

    let prefix = try SharedPrefix.locate(prefixPath.path, allowedRoots: [tempDir])

    // Create wrong c: link
    let dosdevicesPath = prefixPath.appendingPathComponent("dosdevices")
    let cDrivePath = dosdevicesPath.appendingPathComponent("c:")
    try FileManager.default.removeItem(at: cDrivePath)
    try createSymlink(at: cDrivePath, to: "wrong/path")

    // Create valid e: drive and also a wrong one
    let eDriveRealPath = tempDir.appendingPathComponent("e_drive")
    try FileManager.default.createDirectory(at: eDriveRealPath, withIntermediateDirectories: true)
    let eDrivePath = dosdevicesPath.appendingPathComponent("e:")
    try createSymlink(at: eDrivePath, to: "wrong/target")

    // Create runtime with wine.inf for updateStamp test
    let runtimePath = tempDir.appendingPathComponent("runtime")
    try FileManager.default.createDirectory(at: runtimePath.appendingPathComponent("share/wine"), withIntermediateDirectories: true)
    let wineInfPath = runtimePath.appendingPathComponent("share/wine/wine.inf")
    try "test".write(to: wineInfPath, atomically: true, encoding: .utf8)

    // Create .update-timestamp with a different value (mismatch)
    let timestampPath = prefixPath.appendingPathComponent(".update-timestamp")
    try "12345".write(to: timestampPath, atomically: true, encoding: .utf8)

    // Test with updateStamp mismatch
    let problems = prefix.problems(runtime: runtimePath, drives: ["e": eDriveRealPath.path])

    #expect(problems.contains { if case .cDrive = $0 { return true } else { return false } })
    #expect(problems.contains { if case .driveTarget("e", actual: "wrong/target", expected: eDriveRealPath.path) = $0 { return true } else { return false } })
    #expect(problems.contains { if case .updateStamp = $0 { return true } else { return false } })

    // Now test with matching updateStamp
    let wineInfInfo = try FileManager.default.attributesOfItem(atPath: wineInfPath.path)
    let wineInfMtime = (wineInfInfo[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let wineInfMtimeInt = Int64(wineInfMtime)
    try wineInfMtimeInt.description.write(to: timestampPath, atomically: true, encoding: .utf8)
    var times = [timeval(tv_sec: Int(wineInfMtime), tv_usec: 0), timeval(tv_sec: Int(wineInfMtime), tv_usec: 0)]
    _ = utimes(wineInfPath.path, &times)

    // Re-read prefix to get fresh state
    let prefix2 = try SharedPrefix.locate(prefixPath.path, allowedRoots: [tempDir])
    let problems2 = prefix2.problems(runtime: runtimePath, drives: ["e": eDriveRealPath.path])

    // Assert that matching updateStamp gives no updateStamp problem (but still has the other problems)
    #expect(!problems2.contains { if case .updateStamp = $0 { return true } else { return false } })
  }

  // MARK: - Test 8b: Unreadable/non-integer updateStamp

  @Test func unreadableUpdateStamp() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let prefixPath = tempDir.appendingPathComponent("Prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixPath)

    let prefix = try SharedPrefix.locate(prefixPath.path, allowedRoots: [tempDir])

    // Create runtime with wine.inf for updateStamp test
    let runtimePath = tempDir.appendingPathComponent("runtime")
    try FileManager.default.createDirectory(at: runtimePath.appendingPathComponent("share/wine"), withIntermediateDirectories: true)
    let wineInfPath = runtimePath.appendingPathComponent("share/wine/wine.inf")
    try "test".write(to: wineInfPath, atomically: true, encoding: .utf8)

    // Create .update-timestamp with non-integer value
    let timestampPath = prefixPath.appendingPathComponent(".update-timestamp")
    try "not-an-integer".write(to: timestampPath, atomically: true, encoding: .utf8)

    // Stat wine.inf to get its mtime
    var wineInfInfo = stat()
    guard stat(wineInfPath.path, &wineInfInfo) == 0 else {
      return
    }
    let expectedMtimeString = String(Int64(wineInfInfo.st_mtimespec.tv_sec))

    let problems = prefix.problems(runtime: runtimePath, drives: [:])

    // unreadable/non-integer stamp should give .updateStamp(prefix: nil, runtime: <mtime>)
    #expect(problems.contains {
      if case .updateStamp(prefix: nil, runtime: expectedMtimeString) = $0 {
        return true
      } else {
        return false
      }
    })
  }

  // MARK: - Test 8c: Healthy prefix with relative link targets (S9)

  @Test func healthyPrefixWithRelativeLinks() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let prefixPath = tempDir.appendingPathComponent("Prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixPath)

    // Create e: drive target in a separate directory
    let eDriveRealPath = tempDir.appendingPathComponent("e_drive")
    try FileManager.default.createDirectory(at: eDriveRealPath, withIntermediateDirectories: true)

    let prefix = try SharedPrefix.locate(prefixPath.path, allowedRoots: [tempDir])

    // The prefix already has c: -> ../drive_c (relative link)
    // Add e: drive with a relative link (validates separately)
    let dosdevicesPath = prefixPath.appendingPathComponent("dosdevices")
    let eDrivePath = dosdevicesPath.appendingPathComponent("e:")
    try createSymlink(at: eDrivePath, to: eDriveRealPath.path)

    // Create matching .update-timestamp
    let runtimePath = tempDir.appendingPathComponent("runtime")
    try FileManager.default.createDirectory(at: runtimePath.appendingPathComponent("share/wine"), withIntermediateDirectories: true)
    let wineInfPath = runtimePath.appendingPathComponent("share/wine/wine.inf")
    try "test".write(to: wineInfPath, atomically: true, encoding: .utf8)

    let wineInfInfo = try FileManager.default.attributesOfItem(atPath: wineInfPath.path)
    let wineInfMtime = (wineInfInfo[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let wineInfMtimeInt = Int64(wineInfMtime)
    let timestampPath = prefixPath.appendingPathComponent(".update-timestamp")
    try wineInfMtimeInt.description.write(to: timestampPath, atomically: true, encoding: .utf8)

    let problems = prefix.problems(runtime: runtimePath, drives: ["e": eDriveRealPath.path])

    // Healthy prefix returns no problems
    #expect(problems == [])
  }

  // MARK: - Test 9: Repair plan and execution

  @Test func repairPlanAndExecution() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let prefixPath = tempDir.appendingPathComponent("Prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixPath)

    let prefix = try SharedPrefix.locate(prefixPath.path, allowedRoots: [tempDir])

    // Remove c: drive to make it repairable and create wrong e: link
    let dosdevicesPath = prefixPath.appendingPathComponent("dosdevices")
    let cDrivePath = dosdevicesPath.appendingPathComponent("c:")
    try FileManager.default.removeItem(at: cDrivePath)

    // Create a wrong e: drive link
    let eTargetPath = tempDir.appendingPathComponent("e_drive")
    try FileManager.default.createDirectory(at: eTargetPath, withIntermediateDirectories: true)
    let eDrivePath = dosdevicesPath.appendingPathComponent("e:")
    try createSymlink(at: eDrivePath, to: "wrong/path")

    let drives = ["e": eTargetPath.path]
    let plan = prefix.repairPlan(drives: drives)

    // Plan contains ONLY missing links: c: (removed) and f: (declared, absent, target is a dir).
    // The existing e: link with another target is never planned (spec: repair never touches it).
    let fTargetPath = tempDir.appendingPathComponent("f_drive")
    try FileManager.default.createDirectory(at: fTargetPath, withIntermediateDirectories: true)
    let fDrivePath = dosdevicesPath.appendingPathComponent("f:")
    let plan2 = prefix.repairPlan(drives: ["e": eTargetPath.path, "f": fTargetPath.path])
    #expect(plan2.map(\.letter) == ["c", "f"])
    #expect(!plan.contains { $0.letter == "e" })
    #expect(plan.map(\.letter) == ["c"])

    try prefix.repair(plan2)

    // c: and f: were created; e: is unchanged.
    #expect(readLink(cDrivePath.path) == "../drive_c")
    #expect(readLink(fDrivePath.path) == fTargetPath.path)
    #expect(readLink(eDrivePath.path) == "wrong/path")
  }

  // MARK: - Test 10: HubPaths prepareTree

  @Test func hubPathsPrepareTree() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let testRoot = tempDir.appendingPathComponent("hub_test", isDirectory: true)
    try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)

    let paths = HubPaths(root: testRoot)
    try paths.prepareTree()

    // Verify directories were created
    #expect(FileManager.default.fileExists(atPath: paths.hub.path))
    #expect(FileManager.default.fileExists(atPath: paths.state.path))
    #expect(FileManager.default.fileExists(atPath: paths.leases.path))

    // T16: Check permissions on state - must be exactly 0o700
    var stateInfo = stat()
    guard lstat(paths.state.path, &stateInfo) == 0 else {
      Issue.record("Failed to stat state directory")
      return
    }
    #expect((stateInfo.st_mode & 0o777) == 0o700)
  }

  // MARK: - Test 11: HubPaths prepareTree on missing root

  @Test func hubPathsPrepareTreeMissingRoot() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)

    let missingRoot = tempDir.appendingPathComponent("missing_\(UUID().uuidString)")
    let paths = HubPaths(root: missingRoot)

    var errorThrown = false
    do {
      try paths.prepareTree()
    } catch {
      errorThrown = isCase(error, { if case .volumeMissing = $0 { return true } else { return false } })
    }
    #expect(errorThrown)

    // Verify nothing was created
    #expect(!FileManager.default.fileExists(atPath: missingRoot.path))
  }

  // MARK: - Test 11b: prepareTree with missing volume throws volumeMissing

  @Test func prepareTreeMissingVolume() throws {
    let missingVolumeUUID = UUID().uuidString
    let missingVolumePath = "/Volumes/HubTestMissing-\(missingVolumeUUID)"
    let paths = HubPaths(root: URL(fileURLWithPath: missingVolumePath, isDirectory: true))

    #expect { try paths.prepareTree() } throws: { ($0 as? HubError) == .volumeMissing(missingVolumePath) }

    // Verify nothing was created
    #expect(!FileManager.default.fileExists(atPath: missingVolumePath))
  }

  // MARK: - Test 12: HubConfig round-trip

  @Test func hubConfigRoundTrip() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let configPath = tempDir.appendingPathComponent("hub.json")
    let originalConfig = HubConfig(
      schemaVersion: 1,
      prefix: "/tmp/prefix",
      runtime: "hub-0",
      runtimeManifestSHA256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      generation: 1
    )

    try originalConfig.write(to: configPath)
    let readConfig = try HubConfig.read(configPath)

    #expect(readConfig == originalConfig)
  }

  // MARK: - Test 12b: HubConfig rejects .. prefix

  @Test func hubConfigRejectsDoubleDot() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let configPath = tempDir.appendingPathComponent("hub.json")
    let badConfig = HubConfig(
      schemaVersion: 1,
      prefix: "/tmp/../prefix",  // Invalid: contains ..
      runtime: "hub-0",
      runtimeManifestSHA256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      generation: 1
    )

    // write() validates first (S12), so it must refuse to produce the file at all.
    var writeError: Error?
    do { try badConfig.write(to: configPath) } catch { writeError = error }
    #expect(writeError.map(isInvalid) == true)
    #expect(!FileManager.default.fileExists(atPath: configPath.path))

    // read() must reject a hand-written file with a ".." prefix.
    let json = """
    {"schemaVersion":1,"prefix":"/tmp/../prefix","runtime":"hub-0",
     "runtimeManifestSHA256":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","generation":1}
    """
    try Data(json.utf8).write(to: configPath)

    var readError: Error?
    do { _ = try HubConfig.read(configPath) } catch { readError = error }
    #expect(readError.map(isInvalid) == true)
  }

  // MARK: - Test 13: HubConfig rejects unknown keys

  @Test func hubConfigRejectsUnknownKeys() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let configPath = tempDir.appendingPathComponent("hub.json")
    let jsonString = """
    {
      "schemaVersion": 1,
      "prefix": "/tmp/prefix",
      "runtime": "hub-0",
      "runtimeManifestSHA256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      "generation": 1,
      "unknownKey": "value"
    }
    """
    let jsonData = Data(jsonString.utf8)

    try jsonData.write(to: configPath)

    var errorThrown = false
    do {
      _ = try HubConfig.read(configPath)
    } catch {
      errorThrown = isInvalid(error)
    }
    #expect(errorThrown)
  }

  // MARK: - Test 14: HubConfig rejects symlinked hub.json

  @Test func hubConfigRejectsSymlink() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let realConfigPath = tempDir.appendingPathComponent("real_hub.json")
    let symlinkPath = tempDir.appendingPathComponent("hub.json")

    let config = HubConfig(
      schemaVersion: 1,
      prefix: "/tmp/prefix",
      runtime: "hub-0",
      runtimeManifestSHA256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
      generation: 1
    )

    try config.write(to: realConfigPath)
    try createSymlink(at: symlinkPath, to: realConfigPath.path)

    var errorThrown = false
    do {
      _ = try HubConfig.read(symlinkPath)
    } catch {
      errorThrown = isCase(error, { if case .io = $0 { return true } else { return false } })
    }
    #expect(errorThrown)
  }

  // MARK: - T14: Hop containment chain root/l1 -> outside/l2 -> root/Prefix refused

  @Test func hopChainEscapeRefused() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    // Create structure: root/l1 -> outside/l2 -> root/Prefix
    let root = tempDir.appendingPathComponent("root")
    let outside = tempDir.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

    let l1 = root.appendingPathComponent("l1")
    let l2 = outside.appendingPathComponent("l2")
    let prefixPath = root.appendingPathComponent("Prefix")
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixPath)

    // l1 -> l2, l2 -> Prefix
    try createSymlink(at: l1, to: l2.path)
    try createSymlink(at: l2, to: prefixPath.path)

    var errorThrown = false
    do {
      _ = try SharedPrefix.locate(l1.path, allowedRoots: [root])
    } catch {
      errorThrown = isUnsafePath(error)
    }
    #expect(errorThrown)
  }

  // MARK: - T14: Sibling prefix root vs rootX refused

  @Test func siblingPrefixRefused() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let root = tempDir.appendingPathComponent("root")
    let rootX = tempDir.appendingPathComponent("rootX")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: rootX, withIntermediateDirectories: true)

    let prefixInRootX = rootX.appendingPathComponent("Prefix")
    try FileManager.default.createDirectory(at: prefixInRootX, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixInRootX)

    // Try to access prefix in rootX from root (should fail - not in allowed root)
    var errorThrown = false
    do {
      _ = try SharedPrefix.locate(prefixInRootX.path, allowedRoots: [root])
    } catch {
      errorThrown = isUnsafePath(error)
    }
    #expect(errorThrown)
  }

  // MARK: - T14: Exactly 8 hops accepted, 9 refused

  @Test func symlinkHopLimit() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let prefixPath = tempDir.appendingPathComponent("Prefix")
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixPath)

    // Chain of exactly 8 links: link0 -> link1 -> ... -> link7 -> Prefix
    for i in 0..<8 {
      let target = i < 7 ? tempDir.appendingPathComponent("link\(i + 1)").path : prefixPath.path
      try createSymlink(at: tempDir.appendingPathComponent("link\(i)"), to: target)
    }

    // 8 hops are accepted
    let located = try SharedPrefix.locate(tempDir.appendingPathComponent("link0").path, allowedRoots: [tempDir])
    #expect(located.hops.count == 8)

    // Now create a 9th hop
    let link9 = tempDir.appendingPathComponent("link9")
    try createSymlink(at: link9, to: tempDir.appendingPathComponent("link0").path)

    // 9 hops should fail
    var errorThrown9Hops = false
    do {
      _ = try SharedPrefix.locate(link9.path, allowedRoots: [tempDir])
    } catch {
      errorThrown9Hops = isUnsafePath(error)
    }
    #expect(errorThrown9Hops)
  }

  // MARK: - T14: Malicious repair step with "../../x" letter and "/" target

  @Test func maliciousRepairStepRefused() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let prefixPath = tempDir.appendingPathComponent("Prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixPath)

    let prefix = try SharedPrefix.locate(prefixPath.path, allowedRoots: [tempDir])

    // Create malicious repair step
    let maliciousLetter = "../../x"
    let maliciousTarget = "/"

    let plan = [SharedPrefix.RepairStep(letter: maliciousLetter, target: maliciousTarget)]

    var errorThrownRepair = false
    do {
      try prefix.repair(plan)
    } catch {
      errorThrownRepair = isUnsafePath(error)
    }
    #expect(errorThrownRepair)

    // Verify nothing was created in parent directories
    #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("x").path))
  }

  // MARK: - Test 15: HubPaths runtime rejects invalid ids

  @Test func hubPathsRuntimeRejectsInvalidIds() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let paths = HubPaths(root: tempDir)

    var errorThrownRuntime = false
    do {
      _ = try paths.runtime("../x")
    } catch {
      errorThrownRuntime = isInvalid(error)  // spec: invalid ids throw .invalid
    }
    #expect(errorThrownRuntime)
  }

  // MARK: - Test 16: Missing declared drive target directory not planned

  @Test func missingDeclaredDriveTargetNotPlanned() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let prefixPath = tempDir.appendingPathComponent("Prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixPath)

    let prefix = try SharedPrefix.locate(prefixPath.path, allowedRoots: [tempDir])

    // Non-existent target path
    let nonexistentPath = tempDir.appendingPathComponent("nonexistent_drive")
    let drives = ["f": nonexistentPath.path]

    let plan = prefix.repairPlan(drives: drives)

    // f: should NOT be in the plan because its target doesn't exist
    #expect(!plan.contains { $0.letter == "f" })
  }

  // MARK: - Test 17: Declared drive under missing volume not planned

  @Test func declaredDriveUnderMissingVolumeNotPlanned() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let prefixPath = tempDir.appendingPathComponent("Prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixPath)

    let prefix = try SharedPrefix.locate(prefixPath.path, allowedRoots: [tempDir])

    // Target under missing volume
    let missingVolumePath = "/Volumes/HubTestMissing-\(UUID().uuidString)/path"
    let drives = ["g": missingVolumePath]

    let plan = prefix.repairPlan(drives: drives)

    // g: should NOT be in the plan
    #expect(!plan.contains { $0.letter == "g" })
  }

  // MARK: - Test 18: Unreachable drive link detection

  @Test func unreachableDriveLinkDetection() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let prefixPath = tempDir.appendingPathComponent("Prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixPath)

    let prefix = try SharedPrefix.locate(prefixPath.path, allowedRoots: [tempDir])

    // Create a link to a nonexistent path
    let dosdevicesPath = prefixPath.appendingPathComponent("dosdevices")
    let unreachableLinkPath = dosdevicesPath.appendingPathComponent("h:")
    let nonexistentTarget = tempDir.appendingPathComponent("nonexistent_target").path
    try createSymlink(at: unreachableLinkPath, to: nonexistentTarget)

    let drives: [String: String] = [:]
    let problems = prefix.problems(runtime: nil, drives: drives)

    // Should have driveUnreachable problem
    #expect(problems.contains { if case .driveUnreachable("h", _) = $0 { return true } else { return false } })
  }

  // MARK: - Test 19: First allowed root restriction

  @Test func firstAllowedRootRestriction() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let root1 = tempDir.appendingPathComponent("root1", isDirectory: true)
    let root2 = tempDir.appendingPathComponent("root2", isDirectory: true)
    try FileManager.default.createDirectory(at: root1, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root2, withIntermediateDirectories: true)

    let prefixPath = root2.appendingPathComponent("Prefix", isDirectory: true)
    try FileManager.default.createDirectory(at: prefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: prefixPath)

    // Try to locate with root1 first (which doesn't contain the prefix)
    // This should fail because the resolved path must be under the first root
    var errorThrownFirstRoot = false
    do {
      _ = try SharedPrefix.locate(prefixPath.path, allowedRoots: [root1, root2])
    } catch {
      errorThrownFirstRoot = isUnsafePath(error)
    }
    #expect(errorThrownFirstRoot)
  }

  // MARK: - Test 20: Stale prefix rejection

  @Test func stalePrefixRejection() throws {
    let tempDir = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path, isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let stalePrefixPath = tempDir.appendingPathComponent("Prefix.internal-old-123", isDirectory: true)
    try FileManager.default.createDirectory(at: stalePrefixPath, withIntermediateDirectories: true)
    try createPrefixStructure(at: stalePrefixPath)

    var errorThrownStale = false
    do {
      _ = try SharedPrefix.locate(stalePrefixPath.path, allowedRoots: [tempDir])
    } catch {
      errorThrownStale = isUnsafePath(error)
    }
    #expect(errorThrownStale)
  }

  // MARK: - Helper functions

  private func realPath(_ path: String) -> String? {
    guard let resolved = Darwin.realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }

  private func readLink(_ path: String) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let length = Darwin.readlink(path, &buffer, buffer.count - 1)
    guard length > 0 else { return nil }
    return String(bytes: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, encoding: .utf8)
  }

  private func createPrefixStructure(at path: URL) throws {
    try FileManager.default.createDirectory(at: path.appendingPathComponent("drive_c"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: path.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)

    try "".write(to: path.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)
    try "".write(to: path.appendingPathComponent("user.reg"), atomically: true, encoding: .utf8)

    // Create c: drive link
    let dosdevicesPath = path.appendingPathComponent("dosdevices")
    let cDrivePath = dosdevicesPath.appendingPathComponent("c:")
    try createSymlink(at: cDrivePath, to: "../drive_c")
  }

  private func createSymlink(at path: URL, to target: String) throws {
    let result = symlink(target, path.path)
    guard result == 0 else {
      throw NSError(domain: "symlink", code: Int(errno))
    }
  }
}

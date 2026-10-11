import Foundation
import Testing

@testable import HubCore

/// A valid plan as JSON text. `steps` replaces the default single step; `extra` is spliced into
/// the top-level object (for unknown-key tests).
func datastorePlanJSON(
  volume: String = "/vol", protected: [String]? = nil, allowedRoots: [String]? = nil,
  backupDir: String? = nil, schemaVersion: Int = 1, extra: String = "", steps: String? = nil
) -> Data {
  func array(_ items: [String]) -> String {
    "[" + items.map { "\"\($0)\"" }.joined(separator: ",") + "]"
  }
  let backup = backupDir ?? "\(volume)/Backups/run"
  let defaultSteps = """
    [{"id":"S01-backup","title":"Create the backup folder","operations":[
      {"op":"mkdir","path":"\(backup)","mode":493}]}]
    """
  let text = """
    {"schemaVersion":\(schemaVersion),"id":"test-plan","volume":"\(volume)",
     "protected":\(array(protected ?? ["\(volume)/Bundles"])),
     "allowedRoots":\(array(allowedRoots ?? [volume])),
     "backupDir":"\(backup)","journal":"\(backup)/journal.jsonl"\(extra),
     "steps":\(steps ?? defaultSteps)}
    """
  return Data(text.utf8)
}

/// The default first step followed by `more`, as a JSON array.
private func steps(_ more: String...) -> String {
  let first = """
    {"id":"S01-backup","title":"Create the backup folder","operations":[
      {"op":"mkdir","path":"/vol/Backups/run","mode":493}]}
    """
  return "[" + ([first] + more).joined(separator: ",") + "]"
}

private func step(_ id: String = "S02-test", operations: String, extra: String = "") -> String {
  "{\"id\":\"\(id)\",\"title\":\"Test\"\(extra),\"operations\":[\(operations)]}"
}

private func decodingFails(_ data: Data, containing fragment: String) -> Bool {
  do {
    _ = try DatastorePlan.decode(data)
    return false
  } catch {
    return text(of: error).contains(fragment)
  }
}

@Suite struct DatastorePlanTests {
  @Test func aValidPlanDecodes() throws {
    let plan = try DatastorePlan.decode(datastorePlanJSON())
    #expect(plan.id == "test-plan")
    #expect(plan.steps.count == 1)
    #expect(plan.steps[0].operations == [.mkdir(path: "/vol/Backups/run", mode: 0o755)])
  }

  @Test func everyOperationAndCheckDecodes() throws {
    let operations = """
      {"op":"mkdir","path":"/vol/a","mode":448},
      {"op":"rename","from":"/vol/a","to":"/vol/b"},
      {"op":"symlink","path":"/vol/l","target":"b"},
      {"op":"replaceSymlink","path":"/vol/l","target":"c","expectedTarget":"b"},
      {"op":"backup","path":"/vol/f"},
      {"op":"rewriteText","path":"/vol/f","find":"x","replace":"y","expectedCount":1},
      {"op":"writeHubConfig","path":"/vol/Hub/hub.json","prefix":"/vol/Prefix","runtime":"hub-0",
       "runtimeManifest":"/vol/Runtimes/hub-0.manifest",
       "runtimeManifestSHA256":"\(String(repeating: "a", count: 64))","generation":0}
      """
    let checks = """
      {"check":"exists","path":"/vol/a","kind":"directory"},{"check":"absent","path":"/vol/z"},
      {"check":"notSymlink","path":"/vol/a"},
      {"check":"symlinkTarget","path":"/vol/l","target":"c"},
      {"check":"sameFile","a":"/vol/a","b":"/vol/b"},
      {"check":"textContains","path":"/vol/f","text":"y","count":1},
      {"check":"vdfParses","path":"/vol/f"},{"check":"shellSyntax","path":"/vol/f"},
      {"check":"hubConfigValid","path":"/vol/Hub/hub.json","prefix":"/vol/Prefix"},
      {"check":"prefixLocates","path":"/vol/Prefix","allowedRoots":["/vol"],"resolved":"/vol/Prefix"},
      {"check":"noWineProcess"},{"check":"noOpenFiles","path":"/vol/a"},
      {"check":"prefixNotInUse","path":"/vol/Prefix"},
      {"check":"prefixNotInUse","path":"/vol/Prefix","aliases":["/vol/Alias"]},
      {"check":"quietFor","path":"/vol/Prefix","minutes":10}
      """
    let second = step(operations: operations, extra: ",\"preconditions\":[\(checks)]")
    let plan = try DatastorePlan.decode(datastorePlanJSON(steps: steps(second)))
    #expect(plan.steps[1].operations.count == 7)
    #expect(plan.steps[1].preconditions.count == 15)
    #expect(plan.steps[1].preconditions.last == .quietFor(path: "/vol/Prefix", minutes: 10))
  }

  @Test func anUnknownTopLevelKeyIsRejected() {
    #expect(decodingFails(datastorePlanJSON(extra: ",\"surprise\":1"), containing: "Unknown keys"))
  }

  @Test func anUnknownOperationOrCheckKeyIsRejected() {
    let badOp = step(operations: "{\"op\":\"mkdir\",\"path\":\"/vol/a\",\"mode\":493,\"x\":1}")
    #expect(decodingFails(datastorePlanJSON(steps: steps(badOp)), containing: "Unknown keys: x"))
    let badCheck = step(
      operations: "{\"op\":\"mkdir\",\"path\":\"/vol/a\",\"mode\":493}",
      extra: ",\"verify\":[{\"check\":\"absent\",\"path\":\"/vol/a\",\"y\":2}]")
    #expect(decodingFails(datastorePlanJSON(steps: steps(badCheck)), containing: "Unknown keys: y"))
    let unknownOp = step(operations: "{\"op\":\"chmod\",\"path\":\"/vol/a\"}")
    #expect(decodingFails(datastorePlanJSON(steps: steps(unknownOp)), containing: "Unknown op"))
  }

  @Test func theSchemaVersionMustBeOne() {
    #expect(
      decodingFails(datastorePlanJSON(schemaVersion: 2), containing: "schemaVersion must be 1"))
  }

  @Test func relativeAndNonNormalisedPathsAreRejected() {
    let relative = step(operations: "{\"op\":\"mkdir\",\"path\":\"vol/a\",\"mode\":493}")
    #expect(decodingFails(datastorePlanJSON(steps: steps(relative)), containing: "vol/a"))
    let dotDot = step(operations: "{\"op\":\"mkdir\",\"path\":\"/vol/x/../a\",\"mode\":493}")
    #expect(
      decodingFails(
        datastorePlanJSON(steps: steps(dotDot)), containing: "not an absolute, normalised"))
    let doubled = step(operations: "{\"op\":\"mkdir\",\"path\":\"/vol//a\",\"mode\":493}")
    #expect(
      decodingFails(
        datastorePlanJSON(steps: steps(doubled)), containing: "not an absolute, normalised"))
    let trailing = step(operations: "{\"op\":\"mkdir\",\"path\":\"/vol/a/\",\"mode\":493}")
    #expect(
      decodingFails(
        datastorePlanJSON(steps: steps(trailing)), containing: "not an absolute, normalised"))
  }

  @Test func anOperationUnderAProtectedPathIsRejected() {
    let inside = step(operations: "{\"op\":\"mkdir\",\"path\":\"/vol/Bundles/new\",\"mode\":493}")
    #expect(decodingFails(datastorePlanJSON(steps: steps(inside)), containing: "protected path"))
    let renamed = step(
      operations: "{\"op\":\"rename\",\"from\":\"/vol/a\",\"to\":\"/vol/Bundles\"}")
    #expect(decodingFails(datastorePlanJSON(steps: steps(renamed)), containing: "protected path"))
    // A symlink may point into a protected path; only the link itself is a mutation.
    let pointing = step(
      operations: "{\"op\":\"symlink\",\"path\":\"/vol/l\",\"target\":\"/vol/Bundles\"}")
    #expect(!decodingFails(datastorePlanJSON(steps: steps(pointing)), containing: "protected"))
  }

  @Test func aMutationThatContainsAProtectedPathIsRejected() {
    let protected = ["/vol/Bundles", "/vol/GameHub/EA Games"]
    let moves = step(
      operations: "{\"op\":\"rename\",\"from\":\"/vol/GameHub\",\"to\":\"/vol/Moved\"}")
    #expect(
      decodingFails(
        datastorePlanJSON(protected: protected, steps: steps(moves)),
        containing: "contains the protected path /vol/GameHub/EA Games"))
    let wholeVolume = step(operations: "{\"op\":\"symlink\",\"path\":\"/vol\",\"target\":\"x\"}")
    #expect(
      decodingFails(
        datastorePlanJSON(protected: protected, steps: steps(wholeVolume)),
        containing: "contains the protected path /vol/Bundles"))
    let sibling = step(
      operations: "{\"op\":\"rename\",\"from\":\"/vol/GameHub/Logs\",\"to\":\"/vol/GameHub/Hub\"}")
    #expect(
      !decodingFails(
        datastorePlanJSON(protected: protected, steps: steps(sibling)), containing: "protected"))
  }

  @Test func theProtectedListMustHoldTheBundlesFolder() {
    #expect(decodingFails(datastorePlanJSON(protected: ["/vol/Other"]), containing: "/vol/Bundles"))
  }

  @Test func aMutationOutsideTheAllowedRootsIsRejected() {
    let outside = step(operations: "{\"op\":\"mkdir\",\"path\":\"/elsewhere/a\",\"mode\":493}")
    #expect(
      decodingFails(
        datastorePlanJSON(steps: steps(outside)), containing: "outside every allowed root"))
  }

  @Test func rewriteTextNeedsAnEarlierBackupInTheSameStep() {
    let rewrite =
      "{\"op\":\"rewriteText\",\"path\":\"/vol/f\",\"find\":\"a\",\"replace\":\"b\",\"expectedCount\":1}"
    #expect(
      decodingFails(
        datastorePlanJSON(steps: steps(step(operations: rewrite))),
        containing: "needs an earlier backup"))
    let earlierStep = step("S02-backup", operations: "{\"op\":\"backup\",\"path\":\"/vol/f\"}")
    let laterStep = step("S03-rewrite", operations: rewrite)
    #expect(
      decodingFails(
        datastorePlanJSON(steps: steps(earlierStep, laterStep)),
        containing: "needs an earlier backup"))
    let together = step(operations: "{\"op\":\"backup\",\"path\":\"/vol/f\"}," + rewrite)
    #expect(!decodingFails(datastorePlanJSON(steps: steps(together)), containing: "backup"))
  }

  @Test func rewriteTextFieldsAreChecked() {
    let backup = "{\"op\":\"backup\",\"path\":\"/vol/f\"},"
    let empty =
      "{\"op\":\"rewriteText\",\"path\":\"/vol/f\",\"find\":\"\",\"replace\":\"b\",\"expectedCount\":1}"
    #expect(
      decodingFails(
        datastorePlanJSON(steps: steps(step(operations: backup + empty))),
        containing: "find must not be empty"))
    let zero =
      "{\"op\":\"rewriteText\",\"path\":\"/vol/f\",\"find\":\"a\",\"replace\":\"b\",\"expectedCount\":0}"
    #expect(
      decodingFails(
        datastorePlanJSON(steps: steps(step(operations: backup + zero))),
        containing: "expectedCount"))
    let same =
      "{\"op\":\"rewriteText\",\"path\":\"/vol/f\",\"find\":\"a\",\"replace\":\"a\",\"expectedCount\":1}"
    #expect(
      decodingFails(
        datastorePlanJSON(steps: steps(step(operations: backup + same))), containing: "identical"))
  }

  @Test func stepIdsMustBeWellFormedAndUnique() {
    let ok = "{\"op\":\"mkdir\",\"path\":\"/vol/a\",\"mode\":493}"
    #expect(
      decodingFails(
        datastorePlanJSON(steps: steps(step("bad-id", operations: ok))), containing: "id must match"
      ))
    #expect(
      decodingFails(
        datastorePlanJSON(steps: steps(step("S1-short", operations: ok))),
        containing: "id must match"))
    let twice = steps(
      step("S02-a", operations: ok),
      step("S02-a", operations: "{\"op\":\"mkdir\",\"path\":\"/vol/b\",\"mode\":493}"))
    #expect(decodingFails(datastorePlanJSON(steps: twice), containing: "Duplicate step id S02-a"))
  }

  @Test func theFirstStepMustCreateTheBackupFolderAndNoLaterStepMayTouchIt() {
    let other =
      "[{\"id\":\"S01-x\",\"title\":\"t\",\"operations\":[{\"op\":\"mkdir\",\"path\":\"/vol/a\",\"mode\":493}]}]"
    #expect(decodingFails(datastorePlanJSON(steps: other), containing: "must create backupDir"))
    let moves = step(
      operations: "{\"op\":\"rename\",\"from\":\"/vol/Backups\",\"to\":\"/vol/Gone\"}")
    #expect(decodingFails(datastorePlanJSON(steps: steps(moves)), containing: "contains backupDir"))
    let writes = step(
      operations: "{\"op\":\"mkdir\",\"path\":\"/vol/Backups/run/mine\",\"mode\":493}")
    #expect(
      decodingFails(
        datastorePlanJSON(steps: steps(writes)), containing: "only the executor writes there"))
  }

  @Test func theJournalMustBeAFileUnderTheBackupFolder() {
    let data = Data(
      """
      {"schemaVersion":1,"id":"p","volume":"/vol","protected":["/vol/Bundles"],"allowedRoots":["/vol"],
       "backupDir":"/vol/Backups/run","journal":"/vol/journal.jsonl",
       "steps":[{"id":"S01-backup","title":"t","operations":[{"op":"mkdir","path":"/vol/Backups/run","mode":493}]}]}
      """.utf8)
    #expect(decodingFails(data, containing: "journal must be a file under backupDir"))
  }

  @Test func newChecksAreValidated() {
    let ok = "{\"op\":\"mkdir\",\"path\":\"/vol/a\",\"mode\":493}"
    let bad = step(
      operations: ok,
      extra: ",\"preconditions\":[{\"check\":\"quietFor\",\"path\":\"/vol/a\",\"minutes\":0},"
        + "{\"check\":\"prefixNotInUse\",\"path\":\"/vol/a\",\"aliases\":[\"rel\"]}]")
    let data = datastorePlanJSON(steps: steps(bad))
    #expect(decodingFails(data, containing: "minutes must be at least 1"))
    #expect(decodingFails(data, containing: "alias is not absolute"))
  }

  @Test func theLoaderRefusesBigFilesAndSymlinks() throws {
    let directory = NSTemporaryDirectory() + "plan-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let big = directory + "/big.json"
    try Data(repeating: 0x20, count: DatastorePlan.maxFileBytes + 1).write(
      to: URL(fileURLWithPath: big))
    #expect(throws: HubError.self) { try DatastorePlan.load(path: big) }

    let good = directory + "/plan.json"
    try datastorePlanJSON().write(to: URL(fileURLWithPath: good))
    #expect(try DatastorePlan.load(path: good).id == "test-plan")
    let link = directory + "/link.json"
    try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: good)
    #expect(throws: HubError.self) { try DatastorePlan.load(path: link) }
    #expect(throws: HubError.self) { try DatastorePlan.load(path: directory + "/missing.json") }
  }
}

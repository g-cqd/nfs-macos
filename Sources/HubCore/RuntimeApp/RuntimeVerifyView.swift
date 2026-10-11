import Foundation

/// A verify report as text or JSON.
struct RuntimeVerifyView {
  let report: RuntimeVerifyReport
  let path: String

  private struct Payload: Encodable {
    let status: String
    let path: String
    let id: String?
    let manifestSHA256: String?
    let expectedSHA256: String?
    let reason: String?
    let checkedFiles: Int
    let problems: [String]
  }

  private var payload: Payload {
    switch report.state {
    case .ok(let info):
      Payload(
        status: report.isOK ? "ok" : "problems", path: path, id: info.id,
        manifestSHA256: info.manifestSHA256, expectedSHA256: nil, reason: nil,
        checkedFiles: report.checkedFiles, problems: report.problems)
    case .notFound:
      Payload(
        status: "notFound", path: path, id: nil, manifestSHA256: nil, expectedSHA256: nil,
        reason: nil, checkedFiles: 0, problems: [])
    case .invalid(let reason):
      Payload(
        status: "invalid", path: path, id: nil, manifestSHA256: nil, expectedSHA256: nil,
        reason: reason, checkedFiles: report.checkedFiles, problems: report.problems)
    case .mismatch(let expected, let actual):
      Payload(
        status: "mismatch", path: path, id: nil, manifestSHA256: actual, expectedSHA256: expected,
        reason: nil, checkedFiles: 0, problems: [])
    }
  }

  func json() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return String(decoding: try encoder.encode(payload), as: UTF8.self)
  }

  func text() -> String {
    switch report.state {
    case .ok(let info):
      var lines = [
        "\(report.isOK ? "OK" : "FAILED"): \(path)",
        "  id: \(info.id)",
        "  manifest SHA-256: \(info.manifestSHA256)",
        "  wine: \(info.wineBinary.path)",
        "  x87sidecar: \(info.x87sidecar?.path ?? "none")",
        "  files verified: \(report.checkedFiles)",
      ]
      lines += report.problems.map { "  problem: \($0)" }
      return lines.joined(separator: "\n") + "\n"
    case .notFound:
      return "NOT FOUND: \(path)\n"
    case .invalid(let reason):
      return "INVALID: \(path)\n  \(reason)\n"
    case .mismatch(let expected, let actual):
      return "MISMATCH: \(path)\n  manifest SHA-256: \(actual)\n  expected:         \(expected)\n"
    }
  }
}

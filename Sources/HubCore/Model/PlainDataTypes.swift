import Foundation

// MARK: - Pending Action

/// An action pending application.
package struct PendingAction: Codable, Equatable, Sendable {
  package let owner: String
  package let action: FixAction

  package init(owner: String, action: FixAction) {
    self.owner = owner
    self.action = action
  }

  package init(from decoder: any Decoder) throws {
    try rejectUnknownKeys(
      decoder, allowed: ["owner", "action"], type: "PendingAction")
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    self.owner = try container.decode(String.self, forKey: AnyCodingKey(stringValue: "owner"))
    self.action = try container.decode(
      FixAction.self, forKey: AnyCodingKey(stringValue: "action"))
  }
}

// MARK: - Launch Plan

/// A compiled plan to launch a game or provider.
package struct LaunchPlan: Codable, Equatable, Sendable {
  package let target: String
  package let runtime: String
  package let prefix: String
  package let executable: String
  package let arguments: [String]
  package let environment: [String: String]
  package let compatdb: String
  package let sessionProfile: [String: String]
  package let pendingActions: [PendingAction]
  package let warnings: [String]
  package let refusals: [String]

  package init(
    target: String, runtime: String, prefix: String, executable: String,
    arguments: [String], environment: [String: String], compatdb: String,
    sessionProfile: [String: String], pendingActions: [PendingAction] = [],
    warnings: [String] = [], refusals: [String] = []
  ) {
    self.target = target
    self.runtime = runtime
    self.prefix = prefix
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
    self.compatdb = compatdb
    self.sessionProfile = sessionProfile
    self.pendingActions = pendingActions
    self.warnings = warnings
    self.refusals = refusals
  }
}

// MARK: - Target Status

/// Status of a target (game or provider).
package struct TargetStatus: Codable, Equatable, Sendable {
  package let target: String
  package let state: ProviderState
  package let reason: String?
  package let pid: Int32?
  package let since: Date?
  package let log: String?
  package let ports: [Int: Bool]

  package init(
    target: String, state: ProviderState, reason: String? = nil,
    pid: Int32? = nil, since: Date? = nil, log: String? = nil,
    ports: [Int: Bool] = [:]
  ) {
    self.target = target
    self.state = state
    self.reason = reason
    self.pid = pid
    self.since = since
    self.log = log
    self.ports = ports
  }
}

// MARK: - Ledger Entry

/// An entry in the change ledger.
package struct LedgerEntry: Codable, Equatable, Sendable {
  package let time: Date
  package let fix: String
  package let target: String
  package let action: FixAction
  package let before: String?
  package let after: String
  package let backup: String?

  package init(
    time: Date, fix: String, target: String, action: FixAction,
    before: String? = nil, after: String, backup: String? = nil
  ) {
    self.time = time
    self.fix = fix
    self.target = target
    self.action = action
    self.before = before
    self.after = after
    self.backup = backup
  }
}

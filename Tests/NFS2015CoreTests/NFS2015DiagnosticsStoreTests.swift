import Foundation
import LauncherCore
import Testing

@testable import NFS2015Core

struct NFS2015DiagnosticsStoreTests {
  private let loud = NFS2015DiagnosticsPreference(
    limitRetinaDesktop: false, seedSafeResolution: true, diagnosticLoggingNextLaunch: true)

  @Test
  func `starts with the safe choices on and the diagnostic log off`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let loaded = NFS2015DiagnosticsStore(support: scratch.root).load()
    #expect(loaded.preference == NFS2015DiagnosticsPreference.standard)
    #expect(loaded.preference.limitRetinaDesktop && loaded.preference.seedSafeResolution)
    #expect(!loaded.preference.diagnosticLoggingNextLaunch)
    #expect(loaded.notice == nil)
  }

  @Test
  func `keeps a choice, reads it back, and writes nothing for the same choice again`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015DiagnosticsStore(support: scratch.root)
    #expect(try store.save(loud))
    #expect(store.load() == NFS2015DiagnosticsStore.Loaded(preference: loud, notice: nil))
    #expect(try !store.save(loud))
  }

  @Test
  func `a missing, damaged or foreign file means the defaults, and says why`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015DiagnosticsStore(support: scratch.root)
    for text in [
      "not json", "{}",
      #"{"version":2,"limitRetinaDesktop":false,"seedSafeResolution":false,"diagnosticLoggingNextLaunch":true}"#,
      String(repeating: " ", count: 5000),
    ] {
      try scratch.write(NFS2015DiagnosticsStore.fileName, text)
      let loaded = store.load()
      #expect(loaded.preference == NFS2015DiagnosticsPreference.standard, "\(text.prefix(20))")
      #expect(loaded.notice?.contains("could not be used") == true)
    }
  }

  @Test
  func `the diagnostic log runs once: taking it switches it off for the next launch`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015DiagnosticsStore(support: scratch.root)
    _ = try store.save(loud)
    #expect(store.take().preference.diagnosticLoggingNextLaunch)
    #expect(!store.load().preference.diagnosticLoggingNextLaunch)
    #expect(!store.take().preference.diagnosticLoggingNextLaunch)
    // The other choices are kept as they were.
    #expect(!store.load().preference.limitRetinaDesktop)
  }

  @Test
  func `if the switch cannot be cleared the log does not run`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015DiagnosticsStore(support: scratch.root)
    _ = try store.save(loud)
    chmod(scratch.root.path, 0o500)
    defer { chmod(scratch.root.path, 0o755) }
    let taken = store.take()
    #expect(!taken.preference.diagnosticLoggingNextLaunch)
    #expect(taken.notice != nil)
  }

  @Test
  func `reset forgets the choice, including an unusable file`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015DiagnosticsStore(support: scratch.root)
    #expect(try !store.reset())
    try scratch.write(NFS2015DiagnosticsStore.fileName, "garbage")
    #expect(try store.reset())
    #expect(store.load().notice == nil)
  }

  @Test
  func `answers a request with an outcome, and refuses a malformed one`() throws {
    let scratch = try Scratch()
    defer { scratch.remove() }
    let store = NFS2015DiagnosticsStore(support: scratch.root)
    #expect(store.apply(NFS2015DiagnosticsRequest(action: .save, preference: loud)) == .saved)
    #expect(store.apply(NFS2015DiagnosticsRequest(action: .save, preference: loud)) == .unchanged)
    #expect(store.apply(NFS2015DiagnosticsRequest(action: .reset)) == .reset)
    #expect(store.apply(NFS2015DiagnosticsRequest(action: .reset)) == .unchanged)
    #expect(store.apply(NFS2015DiagnosticsRequest(action: .save)).refusal != nil)
    #expect(store.apply(NFS2015DiagnosticsRequest(action: .reset, preference: loud)).refusal != nil)
  }
}

import Foundation
import LauncherCore
import NFS2015Core

/// What one Play keeps watching while the game runs: the Wine runtime to start it with, the
/// bounded diagnostic log if the player asked for one, and the crash monitor.
struct NFS2015PlayWatch {
  let runtime: WineRuntime
  let capture: NFS2015DiagnosticCapture?
  let monitor: NFS2015CrashMonitor?

  /// Ends the diagnostic log and the monitor, and returns the newest crash report written.
  func finish() -> NFS2015CrashNotice? {
    if let capture {
      if !capture.finish(timeout: 10) {
        print("The diagnostic log did not close within 10 seconds; its last lines may be missing.")
      }
      if let failure = capture.failure {
        print("The diagnostic log stopped keeping lines: \(failure)")
      }
    }
    return monitor?.stop()
  }
}

extension NFS2015Session {
  /// Carries out a diagnostics request, if this is one, and reads the choice the launch will use.
  ///
  /// A choice that cannot be read is the defaults with a notice, never a failure, so nothing here
  /// can stop Play from starting the game.
  func diagnosticsState(for options: SessionOptions, store: NFS2015DiagnosticsStore)
    -> NFS2015DiagnosticsState
  {
    var outcome: NFS2015DiagnosticsOutcome?
    if options.action == "--configure-diagnostics", let request = options.request {
      do {
        let requested = try JSONDecoder().decode(
          NFS2015DiagnosticsRequest.self, from: BoundedFile.read(request, limit: 4096))
        outcome = store.apply(requested)
      } catch { outcome = .refused(error.localizedDescription) }
    }
    let loaded = store.load()
    return NFS2015DiagnosticsState(
      preference: loaded.preference, notice: loaded.notice, outcome: outcome)
  }

  /// The facts of this launch that every crash report of it carries.
  func crashContext(
    manifest: BundleManifest?, facts: NFS2015DisplayFacts?, plan: NFS2015DisplaySafetyPlan,
    seeded: NFS2015FirstRunOptions.Outcome?, metalFX: NFS2015MetalFXState,
    diagnostics: NFS2015DiagnosticsPreference, tuning: RuntimeTuning,
    experiment: NFS2015ExperimentOverrides, settings: NFS2015Settings
  ) throws(LauncherError) -> NFS2015CrashContext {
    NFS2015CrashContext(
      pins: NFS2015BuildPins(bundle: paths.bundle, manifest: manifest), host: host.host(),
      display: facts, displayPlan: plan, seed: seeded, metalFX: metalFX.preference,
      diagnostics: diagnostics, diagnosticLog: false, settings: settings,
      tuning: try tuning.environment(), experiment: experiment)
  }

  /// Sets up the diagnostic log and the crash monitor for one Play.
  ///
  /// The diagnostic log is one-shot: the switch is cleared before the game starts. It needs an EA
  /// app this Play starts itself, because Wine reads `WINEDEBUG` when a process starts; with a
  /// running EA app adopted it is left switched on and the player is told.
  func startWatch(
    runtime make: (String) -> WineRuntime, adopted: Bool, diagnostics: NFS2015DiagnosticsState,
    store: NFS2015DiagnosticsStore, context: NFS2015CrashContext
  ) -> NFS2015PlayWatch {
    var context = context
    var runtime = make(LaunchEnvironment.silentDebugChannels)
    let log = NFS2015LogFile.path(of: output)
    let folder = log?.deletingLastPathComponent() ?? paths.support.appendingPathComponent("Logs")
    var capture: NFS2015DiagnosticCapture?
    if diagnostics.preference.diagnosticLoggingNextLaunch {
      if adopted {
        print(
          """
          Diagnostic logging was not used: the EA app was already running, and Wine reads its \
          debug channels when a program starts. Quit the EA app and press Play again; the \
          switch stays on.
          """)
      } else if store.take().preference.diagnosticLoggingNextLaunch {
        do {
          capture = try NFS2015DiagnosticCapture(
            folder: folder, stamp: NFS2015DiagnosticLog.stamp(Date()), main: output)
          runtime = make(NFS2015DiagnosticLog.channels)
          context.diagnosticLog = true
          print(
            "Diagnostic logging is on for this launch only: WINEDEBUG=\(NFS2015DiagnosticLog.channels). "
              + "Debug lines go to wine-debug-*.log in the log folder, newest "
              + "\(NFS2015DiagnosticLog.segmentCount) files of "
              + "\(NFS2015DiagnosticLog.segmentBytes / 1_048_576) MiB kept.")
        } catch { print("Diagnostic logging could not start: \(error.localizedDescription)") }
      }
    }
    var monitor: NFS2015CrashMonitor?
    if let log {
      let created = NFS2015CrashMonitor(
        log: log, store: NFS2015CrashReportStore(folder: folder), context: context, host: host,
        debugFiles: { [capture] in capture?.files ?? [] })
      created.start()
      monitor = created
    } else {
      print("Crash reports need the session log as standard output; none will be written.")
    }
    return NFS2015PlayWatch(runtime: runtime, capture: capture, monitor: monitor)
  }
}

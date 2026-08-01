import Foundation

public enum DDCConnectionState: Equatable {
  case checking
  case connected
  case unavailable(reason: DDCUnavailableReason)
}

public enum DDCUnavailableReason: Equatable {
  case noDisplay
  case multipleDisplays
  case noUniqueDisplay
  case monitorUnreachable
  case volumeReadFailed
  case muteFailed
  case communicationFailed
  case toolMissing
  case timedOut
  case external(String)

  public var diagnosticCode: String {
    switch self {
    case .noDisplay: "no_display"
    case .multipleDisplays: "multiple_displays"
    case .noUniqueDisplay: "no_unique_display"
    case .monitorUnreachable: "monitor_unreachable"
    case .volumeReadFailed: "volume_read_failed"
    case .muteFailed: "mute_failed"
    case .communicationFailed: "communication_failed"
    case .toolMissing: "tool_missing"
    case .timedOut: "timed_out"
    case .external: "external_error"
    }
  }
}

public final class DDCService {
  public typealias StateHandler = (DDCConnectionState) -> Void
  public typealias DisplaysHandler = ([DisplayInfo]) -> Void

  private let settings: SettingsStore
  private let runner: CommandRunning
  private let queue = DispatchQueue(label: "de.mlemors.DDCVolumeKeys.ddc", qos: .userInitiated)
  private let stateLock = NSLock()
  private let changeLock = NSLock()
  private let safeMaximumVolume = 60
  private let maximumVolumeChangePerCommand = 4
  private let maximumTrustedReadbackDrift = 8

  private var _isConnected = false
  private var _activeDisplay: DisplayInfo?
  private var activeDisplayMaximumVolume = 100
  private var pendingVolumeChange = 0
  private var isDrainScheduled = false
  private var lastAudibleVolume = 1
  private var trustedVolume = 1

  public var onStateChange: StateHandler?

  public var isConnected: Bool {
    stateLock.withLock { _isConnected }
  }

  public var activeDisplay: DisplayInfo? {
    stateLock.withLock { _activeDisplay }
  }

  public init(settings: SettingsStore, runner: CommandRunning = CommandRunner()) {
    self.settings = settings
    self.runner = runner
    if let lastKnownVolume = settings.lastKnownVolume {
      self.trustedVolume = min(max(lastKnownVolume, 0), safeMaximumVolume)
      if trustedVolume > 0 {
        self.lastAudibleVolume = trustedVolume
      }
    }
  }

  public func discoverDisplays(completion: @escaping DisplaysHandler) {
    queue.async { [weak self] in
      guard let self else { return }
      self.invalidateActiveDisplay()

      guard self.ensureToolExists() else {
        self.completeOnMain([], completion: completion)
        return
      }

      let result = self.run(arguments: ["display", "list"])
      let candidates =
        result.succeeded
        ? M1DDCOutputParser.displays(from: result.standardOutput)
        : []
      let displayMatches = candidates.compactMap { display -> (display: DisplayInfo, maximum: Int)? in
        guard display.name != "(null)" else { return nil }
        let maximum = self.run(arguments: ["display", display.selector, "max", "volume"])
        guard maximum.succeeded,
          let volume = M1DDCOutputParser.integer(from: maximum.standardOutput),
          volume > 0
        else { return nil }
        return (display, volume)
      }
      let displays = displayMatches.map(\.display)

      if displays.count == 1 {
        self.setActiveDisplay(displays[0], maximumVolume: displayMatches[0].maximum)
      } else {
        self.setActiveDisplay(nil)
      }

      if displays.isEmpty {
        self.publish(.unavailable(reason: .noDisplay))
      } else if displays.count > 1 {
        self.publish(.unavailable(reason: .multipleDisplays))
      }

      self.completeOnMain(displays, completion: completion)
    }
  }

  public func probe() {
    if !isConnected { publish(.checking) }
    queue.async { [weak self] in
      guard let self else { return }
      guard self.ensureToolExists(), let display = self.activeDisplay else {
        if self.activeDisplay == nil {
          self.publish(.unavailable(reason: .noUniqueDisplay))
        }
        return
      }

      let result = self.run(arguments: ["display", display.selector, "get", "volume"])
      guard result.succeeded else {
        self.publishFailure(result, fallback: .monitorUnreachable)
        return
      }
      guard self.activeDisplay?.selector == display.selector else { return }

      if let volume = M1DDCOutputParser.integer(from: result.standardOutput) {
        self.acceptReadbackIfPlausible(volume)
      }
      self.publish(.connected)
    }
  }

  public func changeVolume(by delta: Int) {
    guard isConnected else { return }

    let shouldSchedule = changeLock.withLock {
      pendingVolumeChange += delta
      if isDrainScheduled { return false }
      isDrainScheduled = true
      return true
    }

    if shouldSchedule {
      queue.async { [weak self] in self?.drainVolumeChanges() }
    }
  }

  public func toggleMute() {
    queue.async { [weak self] in
      guard let self, self.isConnected, let display = self.activeDisplay else { return }

      let current = self.run(arguments: ["display", display.selector, "get", "volume"])
      guard current.succeeded,
        let volume = M1DDCOutputParser.integer(from: current.standardOutput)
      else {
        self.publishFailure(current, fallback: .volumeReadFailed)
        return
      }

      let trustedCurrent = self.trustedBaseVolume(fromReadback: volume)
      let newVolume: Int
      if trustedCurrent == 0 {
        newVolume = self.safeVolume(max(1, self.lastAudibleVolume))
      } else {
        self.rememberVolume(trustedCurrent)
        newVolume = 0
      }

      let result = self.run(arguments: [
        "display", display.selector, "set", "volume", String(newVolume),
      ])
      guard self.activeDisplay?.selector == display.selector, self.isConnected else { return }
      if result.succeeded {
        self.rememberVolume(newVolume)
        self.publish(.connected)
      } else {
        self.publishFailure(result, fallback: .muteFailed)
      }
    }
  }

  private func drainVolumeChanges() {
    while true {
      guard
        let delta: Int = changeLock.withLock({
          guard pendingVolumeChange != 0 else {
            isDrainScheduled = false
            return nil
          }
          let value = pendingVolumeChange
          pendingVolumeChange = 0
          return value
        })
      else { return }

      guard let display = activeDisplay, isConnected else {
        clearPendingChanges()
        return
      }

      let current = run(arguments: ["display", display.selector, "get", "volume"])
      guard current.succeeded,
        let currentVolume = M1DDCOutputParser.integer(from: current.standardOutput)
      else {
        clearPendingChanges()
        publishFailure(current, fallback: .volumeReadFailed)
        return
      }

      let boundedDelta = max(
        -maximumVolumeChangePerCommand,
        min(maximumVolumeChangePerCommand, delta)
      )
      let baseVolume = trustedBaseVolume(fromReadback: currentVolume)
      let newVolume = safeVolume(baseVolume + boundedDelta)
      let result = run(arguments: [
        "display", display.selector, "set", "volume", String(newVolume),
      ])
      guard result.succeeded else {
        clearPendingChanges()
        publishFailure(result, fallback: .communicationFailed)
        return
      }
      guard activeDisplay?.selector == display.selector, isConnected else {
        clearPendingChanges()
        return
      }

      rememberVolume(newVolume)
    }
  }

  private func completeOnMain(_ displays: [DisplayInfo], completion: @escaping DisplaysHandler) {
    DispatchQueue.main.async { completion(displays) }
  }

  private func invalidateActiveDisplay() {
    stateLock.withLock {
      _activeDisplay = nil
      _isConnected = false
    }
    clearPendingChanges()
  }

  private func setActiveDisplay(_ display: DisplayInfo?, maximumVolume: Int = 100) {
    stateLock.withLock {
      _activeDisplay = display
      activeDisplayMaximumVolume = max(1, maximumVolume)
    }
  }

  private func clearPendingChanges() {
    changeLock.withLock {
      pendingVolumeChange = 0
      isDrainScheduled = false
    }
  }

  private func ensureToolExists() -> Bool {
    guard FileManager.default.isExecutableFile(atPath: settings.m1ddcPath) else {
      publish(.unavailable(reason: .toolMissing))
      return false
    }
    return true
  }

  private func run(arguments: [String]) -> CommandResult {
    runner.run(executablePath: settings.m1ddcPath, arguments: arguments, timeout: 2)
  }

  private func safeVolume(_ volume: Int) -> Int {
    min(max(volume, 0), min(activeDisplayMaximumVolume, safeMaximumVolume))
  }

  private func trustedBaseVolume(fromReadback readback: Int) -> Int {
    let safeReadback = safeVolume(readback)
    if safeReadback <= trustedVolume
      || abs(safeReadback - trustedVolume) <= maximumTrustedReadbackDrift
    {
      return safeReadback
    }
    return trustedVolume
  }

  private func acceptReadbackIfPlausible(_ readback: Int) {
    let volume = trustedBaseVolume(fromReadback: readback)
    rememberVolume(volume)
  }

  private func rememberVolume(_ volume: Int) {
    let safe = safeVolume(volume)
    trustedVolume = safe
    settings.recordLastKnownVolume(safe)
    if safe > 0 {
      lastAudibleVolume = safe
    }
  }

  private func publishFailure(_ result: CommandResult, fallback: DDCUnavailableReason) {
    if result.timedOut {
      publish(.unavailable(reason: .timedOut))
      return
    }
    let error = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
    let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = error.isEmpty ? output : error
    publish(.unavailable(reason: message.isEmpty ? fallback : .external(message)))
  }

  private func publish(_ state: DDCConnectionState) {
    stateLock.withLock {
      if case .connected = state {
        _isConnected = _activeDisplay != nil
      } else {
        _isConnected = false
      }
    }
    DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) }
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}

import DDCVolumeKeysCore
import Darwin
import Foundation

private var failures = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  if condition() {
    print("✓ \(message)")
  } else {
    failures += 1
    print("✗ \(message)")
  }
}

private func waitUntil(timeout: TimeInterval = 1, _ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() { return true }
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
  }
  return condition()
}

private func verifyParsing() {
  let uuid = "10ACB8A0-0000-0000-1419-0104A2435078"
  let displays = M1DDCOutputParser.displays(
    from: """
      [1] Dell U2723QE (\(uuid))
      [2] Studio (Office) (ABCDEF00-1111-2222-3333-444455556666)
      """)
  expect(displays.count == 2, "m1ddc display list is parsed")
  expect(displays.first?.name == "Dell U2723QE", "display name is preserved")
  expect(displays.first?.uuid == uuid, "stable display UUID is extracted")
  expect(
    M1DDCOutputParser.displays(from: "No external display found").isEmpty,
    "malformed output fails closed")
  expect(M1DDCOutputParser.integer(from: "Writing 17\n") == 17, "DDC value is parsed")
}

private func verifyMediaKeys() {
  let down = (MediaKey.volumeUp.rawValue << 16) | (0xA << 8)
  let up = (MediaKey.volumeDown.rawValue << 16) | (0xB << 8)
  expect(
    MediaKeyEventDecoder.decode(data1: down) == MediaKeyEvent(key: .volumeUp, isKeyDown: true),
    "volume-up key is decoded")
  expect(
    MediaKeyEventDecoder.decode(data1: up) == MediaKeyEvent(key: .volumeDown, isKeyDown: false),
    "volume-down key-up is decoded")
  expect(MediaKeyEventDecoder.decode(data1: 99 << 16) == nil, "unrelated keys pass through")
}

private func verifySettings() {
  let suite = "DDCVolumeKeysVerification.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set([["name": "Old display", "uuid": "stable-id"]], forKey: "RuntimeDisplays")
  defaults.set("/usr/bin/true", forKey: "M1DDCPath")
  let settings = SettingsStore(defaults: defaults)
  expect(settings.m1ddcPath == "/usr/bin/true", "m1ddc path can be configured")
  expect(defaults.object(forKey: "RuntimeDisplays") == nil, "old display identifiers are removed")
  settings.recordRuntime(status: "connected", displayCount: 1)
  expect(settings.runtimeStatus == "connected", "runtime status is persisted")
  expect(settings.runtimeDisplayCount == 1, "runtime display count is persisted")
  settings.recordRuntime(displays: [DisplayInfo(index: 1, name: "Dell", uuid: "stable-id")])
  expect(defaults.object(forKey: "RuntimeDisplays") == nil, "display identifiers are not persisted")
}

private func verifyCommandRunner() {
  let runner = CommandRunner()
  let success = runner.run(
    executablePath: "/usr/bin/printf", arguments: ["Writing 4\\n"], timeout: 1)
  expect(success.succeeded && success.standardOutput == "Writing 4\n", "command output is captured")
  let timeout = runner.run(executablePath: "/bin/sleep", arguments: ["2"], timeout: 0.05)
  expect(timeout.timedOut && !timeout.succeeded, "hung commands time out")
  let missing = runner.run(executablePath: "/does/not/exist", arguments: [], timeout: 0.05)
  expect(!missing.succeeded, "missing executable fails safely")
}

private final class FakeRunner: CommandRunning {
  private let handler: ([String]) -> CommandResult
  private let lock = NSLock()
  private var calls: [[String]] = []

  init(handler: @escaping ([String]) -> CommandResult) { self.handler = handler }

  func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
    lock.lock()
    calls.append(arguments)
    lock.unlock()
    return handler(arguments)
  }

  func saw(_ arguments: [String]) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return calls.contains(arguments)
  }
}

private func verifyService() {
  let suite = "DDCVolumeKeysServiceVerification.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  defer { defaults.removePersistentDomain(forName: suite) }
  defaults.set("/usr/bin/true", forKey: "M1DDCPath")
  let uuid = "10ACB8A0-0000-0000-1419-0104A2435078"
  let runner = FakeRunner { args in
    if args == ["display", "list"] {
      return CommandResult(
        status: 0, standardOutput: "[1] Dell (\(uuid))\n[2] (null) (BAD)\n",
        standardError: "", timedOut: false)
    }
    if args.contains("BAD") {
      return CommandResult(status: 1, standardOutput: "failure", standardError: "", timedOut: false)
    }
    if args.suffix(2).elementsEqual(["max", "volume"]) {
      return CommandResult(status: 0, standardOutput: "100\n", standardError: "", timedOut: false)
    }
    if args.suffix(2).elementsEqual(["get", "volume"]) {
      return CommandResult(status: 0, standardOutput: "4\n", standardError: "", timedOut: false)
    }
    return CommandResult(
      status: 0, standardOutput: "Writing 5\n", standardError: "", timedOut: false)
  }
  let service = DDCService(settings: SettingsStore(defaults: defaults), runner: runner)
  var displays: [DisplayInfo] = []
  service.discoverDisplays { displays = $0 }
  expect(waitUntil { displays.count == 1 }, "only volume-capable monitor is selected automatically")
  expect(
    displays.first?.uuid == uuid && service.activeDisplay?.uuid == uuid,
    "automatic target uses the external monitor UUID")

  var state: DDCConnectionState = .checking
  service.onStateChange = { state = $0 }
  service.probe()
  expect(
    waitUntil {
      if case .connected = state { return true }
      return false
    },
    "successful probe enables interception")
  expect(service.isConnected, "connected state is atomic")
  service.changeVolume(by: 1)
  expect(
    waitUntil { runner.saw(["display", uuid, "set", "volume", "5"]) },
    "volume step one sets a safe absolute monitor volume")

  defaults.set(1, forKey: "LastKnownVolume")
  let loudRunner = FakeRunner { args in
    if args == ["display", "list"] {
      return CommandResult(
        status: 0, standardOutput: "[1] Dell (\(uuid))\n",
        standardError: "", timedOut: false)
    }
    if args.suffix(2).elementsEqual(["max", "volume"]) {
      return CommandResult(status: 0, standardOutput: "100\n", standardError: "", timedOut: false)
    }
    if args.suffix(2).elementsEqual(["get", "volume"]) {
      return CommandResult(status: 0, standardOutput: "98\n", standardError: "", timedOut: false)
    }
    return CommandResult(
      status: 0, standardOutput: "Writing 60\n", standardError: "", timedOut: false)
  }
  let loudService = DDCService(settings: SettingsStore(defaults: defaults), runner: loudRunner)
  loudService.discoverDisplays { _ in }
  expect(waitUntil { loudService.activeDisplay?.uuid == uuid }, "safety test selects display")
  loudService.probe()
  expect(waitUntil { loudService.isConnected }, "safety test connects")
  loudService.changeVolume(by: 10)
  expect(
    waitUntil { loudRunner.saw(["display", uuid, "set", "volume", "2"]) },
    "implausible high readback is ignored")
  expect(
    !loudRunner.saw(["display", uuid, "set", "volume", "60"]),
    "volume-up never jumps to the safety ceiling")
  expect(
    !loudRunner.saw(["display", uuid, "set", "volume", "100"]),
    "volume-up never sets monitor volume to 100")

  let failing = FakeRunner { _ in
    CommandResult(status: -1, standardOutput: "", standardError: "", timedOut: true)
  }
  let failedService = DDCService(settings: SettingsStore(defaults: defaults), runner: failing)
  var failedState: DDCConnectionState = .checking
  failedService.onStateChange = { failedState = $0 }
  failedService.discoverDisplays { _ in }
  expect(
    waitUntil {
      if case .unavailable = failedState { return true }
      return false
    },
    "failed discovery disables interception")
  expect(!failedService.isConnected, "failure remains fail-safe")
}

verifyParsing()
verifyMediaKeys()
verifySettings()
verifyCommandRunner()
verifyService()

if failures == 0 {
  print("All DDCVolumeKeys checks passed.")
  exit(EXIT_SUCCESS)
}
print("\(failures) DDCVolumeKeys check(s) failed.")
exit(EXIT_FAILURE)

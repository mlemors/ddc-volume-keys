import Foundation
import XCTest

import DDCVolumeKeysCore

final class M1DDCOutputParserTests: XCTestCase {
  func testParsesDisplayListAndStableUUIDs() {
    let uuid = "10ACB8A0-0000-0000-1419-0104A2435078"
    let displays = M1DDCOutputParser.displays(
      from: """
        [1] Dell U2723QE (\(uuid))
        [2] Studio (Office) (ABCDEF00-1111-2222-3333-444455556666)
        """
    )

    XCTAssertEqual(displays.count, 2)
    XCTAssertEqual(displays.first?.name, "Dell U2723QE")
    XCTAssertEqual(displays.first?.uuid, uuid)
    XCTAssertTrue(M1DDCOutputParser.displays(from: "No external display found").isEmpty)
  }

  func testParsesIntegerFromCommandOutput() {
    XCTAssertEqual(M1DDCOutputParser.integer(from: "Writing 17\n"), 17)
  }
}

final class MediaKeyEventDecoderTests: XCTestCase {
  func testDecodesKeyDownAndKeyUp() {
    let down = (MediaKey.volumeUp.rawValue << 16) | (0xA << 8)
    let up = (MediaKey.volumeDown.rawValue << 16) | (0xB << 8)

    XCTAssertEqual(
      MediaKeyEventDecoder.decode(data1: down),
      MediaKeyEvent(key: .volumeUp, isKeyDown: true)
    )
    XCTAssertEqual(
      MediaKeyEventDecoder.decode(data1: up),
      MediaKeyEvent(key: .volumeDown, isKeyDown: false)
    )
  }

  func testIgnoresUnrelatedKeys() {
    XCTAssertNil(MediaKeyEventDecoder.decode(data1: 99 << 16))
  }
}

final class SettingsStoreTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!

  override func setUp() {
    super.setUp()
    suite = "DDCVolumeKeysTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    defaults = nil
    super.tearDown()
  }

  func testUsesConfiguredM1DDCPath() {
    defaults.set("/usr/bin/true", forKey: "M1DDCPath")

    XCTAssertEqual(SettingsStore(defaults: defaults).m1ddcPath, "/usr/bin/true")
  }

  func testRemovesLegacyDisplayIdentifiersAndDoesNotPersistNewOnes() {
    defaults.set([["name": "Old display", "uuid": "stable-id"]], forKey: "RuntimeDisplays")
    let settings = SettingsStore(defaults: defaults)

    XCTAssertNil(defaults.object(forKey: "RuntimeDisplays"))

    settings.recordRuntime(displays: [DisplayInfo(index: 1, name: "Dell", uuid: "stable-id")])

    XCTAssertNil(defaults.object(forKey: "RuntimeDisplays"))
    XCTAssertEqual(settings.runtimeDisplayCount, 1)
  }

  func testPersistsRuntimeStatusAndLastKnownVolume() {
    let settings = SettingsStore(defaults: defaults)

    settings.recordRuntime(status: "connected", displayCount: 1)
    settings.recordLastKnownVolume(24)

    XCTAssertEqual(settings.runtimeStatus, "connected")
    XCTAssertEqual(settings.runtimeDisplayCount, 1)
    XCTAssertEqual(settings.lastKnownVolume, 24)
  }
}

final class CommandRunnerTests: XCTestCase {
  func testCapturesSuccessfulOutput() {
    let result = CommandRunner().run(
      executablePath: "/usr/bin/printf",
      arguments: ["Writing 4\\n"],
      timeout: 1
    )

    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.standardOutput, "Writing 4\n")
  }

  func testTimesOutHungCommands() {
    let result = CommandRunner().run(
      executablePath: "/bin/sleep",
      arguments: ["2"],
      timeout: 0.05
    )

    XCTAssertTrue(result.timedOut)
    XCTAssertFalse(result.succeeded)
  }

  func testMissingExecutableFailsSafely() {
    let result = CommandRunner().run(
      executablePath: "/does/not/exist",
      arguments: [],
      timeout: 0.05
    )

    XCTAssertFalse(result.succeeded)
  }
}

final class DDCServiceTests: XCTestCase {
  private let uuid = "10ACB8A0-0000-0000-1419-0104A2435078"

  func testDiscoverySelectsOnlyVolumeCapableDisplay() {
    let fixture = makeDefaults()
    let defaults = fixture.defaults
    defer { defaults.removePersistentDomain(forName: fixture.suite) }
    defaults.set("/usr/bin/true", forKey: "M1DDCPath")

    let runner = FakeRunner { args in
      if args == ["display", "list"] {
        return CommandResult(
          status: 0,
          standardOutput: "[1] Dell (\(self.uuid))\n[2] (null) (BAD)\n",
          standardError: "",
          timedOut: false
        )
      }
      if args.contains("BAD") {
        return CommandResult(status: 1, standardOutput: "failure", standardError: "", timedOut: false)
      }
      if args.suffix(2).elementsEqual(["max", "volume"]) {
        return CommandResult(status: 0, standardOutput: "100\n", standardError: "", timedOut: false)
      }
      return CommandResult(status: 0, standardOutput: "Writing 5\n", standardError: "", timedOut: false)
    }
    let service = DDCService(settings: SettingsStore(defaults: defaults), runner: runner)
    let completion = expectation(description: "display discovery")
    var displays: [DisplayInfo] = []

    service.discoverDisplays {
      displays = $0
      completion.fulfill()
    }
    wait(for: [completion], timeout: 2)

    XCTAssertEqual(displays.count, 1)
    XCTAssertEqual(displays.first?.uuid, uuid)
    XCTAssertEqual(service.activeDisplay?.uuid, uuid)
  }

  func testProbeEnablesConnectionAndVolumeChangeIsSafe() {
    let fixture = makeDefaults()
    let defaults = fixture.defaults
    defer { defaults.removePersistentDomain(forName: fixture.suite) }
    defaults.set("/usr/bin/true", forKey: "M1DDCPath")
    let runner = standardRunner(uuid: uuid)
    let service = DDCService(settings: SettingsStore(defaults: defaults), runner: runner)

    discover(service)
    let connected = expectation(description: "service connected")
    service.onStateChange = { state in
      if case .connected = state { connected.fulfill() }
    }
    service.probe()
    wait(for: [connected], timeout: 2)

    XCTAssertTrue(service.isConnected)
    service.changeVolume(by: 1)

    XCTAssertTrue(runner.waitFor(["display", uuid, "set", "volume", "5"]))
  }

  func testImplausibleReadbackDoesNotJumpToUnsafeVolume() {
    let fixture = makeDefaults()
    let defaults = fixture.defaults
    defer { defaults.removePersistentDomain(forName: fixture.suite) }
    defaults.set("/usr/bin/true", forKey: "M1DDCPath")
    defaults.set(1, forKey: "LastKnownVolume")
    let runner = FakeRunner { [uuid] args in
      if args == ["display", "list"] {
        return CommandResult(status: 0, standardOutput: "[1] Dell (\(uuid))\n", standardError: "", timedOut: false)
      }
      if args.suffix(2).elementsEqual(["max", "volume"]) {
        return CommandResult(status: 0, standardOutput: "100\n", standardError: "", timedOut: false)
      }
      if args.suffix(2).elementsEqual(["get", "volume"]) {
        return CommandResult(status: 0, standardOutput: "98\n", standardError: "", timedOut: false)
      }
      return CommandResult(status: 0, standardOutput: "Writing 60\n", standardError: "", timedOut: false)
    }
    let service = DDCService(settings: SettingsStore(defaults: defaults), runner: runner)

    discover(service)
    let connected = expectation(description: "service connected")
    service.onStateChange = { state in
      if case .connected = state { connected.fulfill() }
    }
    service.probe()
    wait(for: [connected], timeout: 2)
    service.changeVolume(by: 10)

    XCTAssertTrue(runner.waitFor(["display", uuid, "set", "volume", "5"]))
    XCTAssertFalse(runner.saw(["display", uuid, "set", "volume", "60"]))
    XCTAssertFalse(runner.saw(["display", uuid, "set", "volume", "100"]))
  }

  func testFailedDiscoveryStaysDisconnected() {
    let fixture = makeDefaults()
    let defaults = fixture.defaults
    defer { defaults.removePersistentDomain(forName: fixture.suite) }
    defaults.set("/usr/bin/true", forKey: "M1DDCPath")
    let runner = FakeRunner { _ in
      CommandResult(status: -1, standardOutput: "", standardError: "", timedOut: true)
    }
    let service = DDCService(settings: SettingsStore(defaults: defaults), runner: runner)
    let unavailable = expectation(description: "service unavailable")
    service.onStateChange = { state in
      if case .unavailable = state { unavailable.fulfill() }
    }

    discover(service)
    wait(for: [unavailable], timeout: 2)

    XCTAssertFalse(service.isConnected)
  }

  private func discover(_ service: DDCService) {
    let completion = expectation(description: "display discovery")
    service.discoverDisplays { _ in completion.fulfill() }
    wait(for: [completion], timeout: 2)
  }

  private func standardRunner(uuid: String) -> FakeRunner {
    FakeRunner { args in
      if args == ["display", "list"] {
        return CommandResult(status: 0, standardOutput: "[1] Dell (\(uuid))\n", standardError: "", timedOut: false)
      }
      if args.suffix(2).elementsEqual(["max", "volume"]) {
        return CommandResult(status: 0, standardOutput: "100\n", standardError: "", timedOut: false)
      }
      if args.suffix(2).elementsEqual(["get", "volume"]) {
        return CommandResult(status: 0, standardOutput: "4\n", standardError: "", timedOut: false)
      }
      return CommandResult(status: 0, standardOutput: "Writing 5\n", standardError: "", timedOut: false)
    }
  }

  private func makeDefaults() -> (defaults: UserDefaults, suite: String) {
    let suite = "DDCVolumeKeysServiceTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
  }
}

private final class FakeRunner: CommandRunning {
  private let handler: ([String]) -> CommandResult
  private let lock = NSLock()
  private var calls: [[String]] = []

  init(handler: @escaping ([String]) -> CommandResult) {
    self.handler = handler
  }

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

  func waitFor(_ arguments: [String], timeout: TimeInterval = 2) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if saw(arguments) { return true }
      Thread.sleep(forTimeInterval: 0.01)
    }
    return saw(arguments)
  }
}

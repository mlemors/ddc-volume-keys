import AppKit
import ApplicationServices
import DDCVolumeKeysCore

final class MediaKeyHandler {
  private let shouldHandle: () -> Bool
  private let volumeUp: (Int) -> Void
  private let volumeDown: (Int) -> Void
  private let toggleMute: () -> Void

  private var lastVolumeKey: MediaKey?
  private var lastVolumeKeyTime: TimeInterval = 0
  private var rapidPressCount = 0

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  init(
    shouldHandle: @escaping () -> Bool,
    volumeUp: @escaping (Int) -> Void,
    volumeDown: @escaping (Int) -> Void,
    toggleMute: @escaping () -> Void
  ) {
    self.shouldHandle = shouldHandle
    self.volumeUp = volumeUp
    self.volumeDown = volumeDown
    self.toggleMute = toggleMute
  }

  var isRunning: Bool {
    guard let eventTap else { return false }
    return CGEvent.tapIsEnabled(tap: eventTap)
  }

  @discardableResult
  func start() -> Bool {
    guard eventTap == nil else { return true }

    let eventType = CGEventType(rawValue: 14)!  // kCGEventSystemDefined
    let mask = CGEventMask(1) << eventType.rawValue
    let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: mask,
        callback: Self.eventTapCallback,
        userInfo: userInfo
      )
    else {
      return false
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    eventTap = tap
    runLoopSource = source
    return true
  }

  @discardableResult
  func ensureRunning() -> Bool {
    guard let eventTap else {
      return start()
    }

    guard !CGEvent.tapIsEnabled(tap: eventTap) else { return true }

    // macOS can disable a tap after a timeout or when another system
    // component temporarily takes over event processing. Try the cheap
    // recovery first, then recreate the tap if it remains disabled.
    CGEvent.tapEnable(tap: eventTap, enable: true)
    if CGEvent.tapIsEnabled(tap: eventTap) {
      return true
    }

    stop()
    return start()
  }

  func stop() {
    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
    }
    runLoopSource = nil
    eventTap = nil
  }

  private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let eventTap {
        CGEvent.tapEnable(tap: eventTap, enable: true)
      }
      return Unmanaged.passUnretained(event)
    }

    guard let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 else {
      return Unmanaged.passUnretained(event)
    }

    guard let mediaKeyEvent = MediaKeyEventDecoder.decode(data1: nsEvent.data1), shouldHandle()
    else {
      return Unmanaged.passUnretained(event)
    }

    if mediaKeyEvent.isKeyDown {
      switch mediaKeyEvent.key {
      case .volumeUp:
        volumeUp(volumeStep(for: .volumeUp))
      case .volumeDown:
        volumeDown(volumeStep(for: .volumeDown))
      case .mute:
        resetVolumeAcceleration()
        toggleMute()
      }
    }

    // Swallow both the key-down and key-up event while DDC handles this display.
    return nil
  }

  private func volumeStep(for key: MediaKey) -> Int {
    let now = ProcessInfo.processInfo.systemUptime
    if lastVolumeKey == key, now - lastVolumeKeyTime <= 0.4 {
      rapidPressCount += 1
    } else {
      rapidPressCount = 1
    }
    lastVolumeKey = key
    lastVolumeKeyTime = now

    switch rapidPressCount {
    case 1...3: return 1
    case 4...7: return 2
    default: return 4
    }
  }

  private func resetVolumeAcceleration() {
    lastVolumeKey = nil
    rapidPressCount = 0
  }

  private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let handler = Unmanaged<MediaKeyHandler>.fromOpaque(userInfo).takeUnretainedValue()
    return handler.handle(type: type, event: event)
  }
}

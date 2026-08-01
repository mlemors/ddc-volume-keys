import Foundation

public final class SettingsStore {
  private enum Key {
    static let m1ddcPath = "M1DDCPath"
    static let runtimeStatus = "RuntimeStatus"
    static let runtimeDisplayCount = "RuntimeDisplayCount"
    static let runtimeLastUpdate = "RuntimeLastUpdate"
    static let lastKnownVolume = "LastKnownVolume"
  }

  private let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    // Remove settings from the pre-0.3 UI, which no longer has user-selectable
    // displays, steps, handling, or a volume HUD.
    defaults.removeObject(forKey: "DisplaySelector")
    defaults.removeObject(forKey: "VolumeStep")
    defaults.removeObject(forKey: "HandlingEnabled")
    defaults.removeObject(forKey: "ShowVolumeHUD")
    defaults.removeObject(forKey: "AccessibilityPromptVersion")
    // Remove display identifiers written by older versions. Runtime
    // diagnostics now retain only the display count.
    defaults.removeObject(forKey: "RuntimeDisplays")
  }

  public var m1ddcPath: String {
    if let configuredPath = defaults.string(forKey: Key.m1ddcPath), !configuredPath.isEmpty {
      return configuredPath
    }
    if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/m1ddc") {
      return "/opt/homebrew/bin/m1ddc"
    }
    return "/usr/local/bin/m1ddc"
  }

  public func recordRuntime(status: String, displayCount: Int? = nil) {
    defaults.set(status, forKey: Key.runtimeStatus)
    defaults.set(Date(), forKey: Key.runtimeLastUpdate)
    if let displayCount {
      defaults.set(displayCount, forKey: Key.runtimeDisplayCount)
    }
  }

  public var runtimeStatus: String? {
    defaults.string(forKey: Key.runtimeStatus)
  }

  public var runtimeDisplayCount: Int? {
    guard defaults.object(forKey: Key.runtimeDisplayCount) != nil else { return nil }
    return defaults.integer(forKey: Key.runtimeDisplayCount)
  }

  public func recordRuntime(displays: [DisplayInfo]) {
    defaults.set(displays.count, forKey: Key.runtimeDisplayCount)
    defaults.set(Date(), forKey: Key.runtimeLastUpdate)
  }

  public var lastKnownVolume: Int? {
    guard defaults.object(forKey: Key.lastKnownVolume) != nil else { return nil }
    return defaults.integer(forKey: Key.lastKnownVolume)
  }

  public func recordLastKnownVolume(_ volume: Int) {
    defaults.set(volume, forKey: Key.lastKnownVolume)
  }
}

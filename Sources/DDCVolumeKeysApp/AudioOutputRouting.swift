import CoreAudio
import DDCVolumeKeysCore
import Foundation

/// Identifies whether the macOS default output is the display controlled by DDC.
/// If CoreAudio cannot identify the output, this deliberately returns false.
enum AudioOutputRouting {
  static func isActiveOutput(_ display: DisplayInfo) -> Bool {
    guard display.name != "Unknown", !display.name.isEmpty else { return false }
    guard let outputName = defaultOutputName() else { return false }

    let displayName = normalize(display.name)
    let activeName = normalize(outputName)
    guard displayName.count >= 4, activeName.count >= 4 else { return false }

    return activeName == displayName
      || activeName.contains(displayName)
      || displayName.contains(activeName)
  }

  private static func defaultOutputName() -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
      AudioObjectID(kAudioObjectSystemObject),
      &address,
      0,
      nil,
      &size,
      &deviceID
    ) == noErr, deviceID != 0 else { return nil }

    address = AudioObjectPropertyAddress(
      mSelector: kAudioObjectPropertyName,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain
    )
    var name: Unmanaged<CFString>?
    size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &name) == noErr,
      let name
    else { return nil }
    return name.takeUnretainedValue() as String
  }

  private static func normalize(_ value: String) -> String {
    value
      .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
      .filter { $0.isLetter || $0.isNumber }
  }
}

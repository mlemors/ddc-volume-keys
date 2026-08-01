public enum MediaKey: Int, Equatable, Sendable {
  // Values from IOKit hidsystem/ev_keymap.h.
  case volumeUp = 0
  case volumeDown = 1
  case mute = 7
}

public struct MediaKeyEvent: Equatable, Sendable {
  public let key: MediaKey
  public let isKeyDown: Bool

  public init(key: MediaKey, isKeyDown: Bool) {
    self.key = key
    self.isKeyDown = isKeyDown
  }
}

public enum MediaKeyEventDecoder {
  public static func decode(data1: Int) -> MediaKeyEvent? {
    let keyCode = (data1 & 0xFFFF_0000) >> 16
    guard let key = MediaKey(rawValue: keyCode) else { return nil }

    let keyFlags = data1 & 0x0000_FFFF
    let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0xA
    return MediaKeyEvent(key: key, isKeyDown: isKeyDown)
  }
}

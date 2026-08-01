import Foundation

public struct DisplayInfo: Equatable, Sendable {
  public let index: Int
  public let name: String
  public let uuid: String

  public init(index: Int, name: String, uuid: String) {
    self.index = index
    self.name = name
    self.uuid = uuid
  }

  public var selector: String { uuid }

  public var menuTitle: String {
    name.isEmpty || name == "Unknown" ? "Display \(index)" : name
  }
}

public enum M1DDCOutputParser {
  public static func displays(from output: String) -> [DisplayInfo] {
    output.split(whereSeparator: \.isNewline).compactMap { rawLine in
      let line = String(rawLine).trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("["), line.hasSuffix(")"),
        let indexEnd = line.firstIndex(of: "]"),
        let separator = line.range(of: " (", options: .backwards)
      else {
        return nil
      }

      let indexStart = line.index(after: line.startIndex)
      guard let index = Int(line[indexStart..<indexEnd]) else { return nil }

      let nameStart = line.index(indexEnd, offsetBy: 2, limitedBy: line.endIndex) ?? line.endIndex
      let name = String(line[nameStart..<separator.lowerBound])
      let uuidStart = separator.upperBound
      let uuidEnd = line.index(before: line.endIndex)
      let uuid = String(line[uuidStart..<uuidEnd])
      guard !uuid.isEmpty else { return nil }

      return DisplayInfo(index: index, name: name, uuid: uuid)
    }
  }

  public static func integer(from output: String) -> Int? {
    output.split(whereSeparator: { !$0.isNumber && $0 != "-" })
      .compactMap { Int($0) }
      .first
  }
}

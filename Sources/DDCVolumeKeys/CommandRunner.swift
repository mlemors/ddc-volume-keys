import Darwin
import Foundation

public struct CommandResult: Equatable {
  public let status: Int32
  public let standardOutput: String
  public let standardError: String
  public let timedOut: Bool

  public init(status: Int32, standardOutput: String, standardError: String, timedOut: Bool) {
    self.status = status
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.timedOut = timedOut
  }

  public var succeeded: Bool { status == 0 && !timedOut }
}

public protocol CommandRunning {
  func run(executablePath: String, arguments: [String], timeout: TimeInterval) -> CommandResult
}

public struct CommandRunner: CommandRunning {
  public init() {}

  public func run(
    executablePath: String,
    arguments: [String],
    timeout: TimeInterval
  ) -> CommandResult {
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
      return CommandResult(
        status: -1,
        standardOutput: "",
        standardError: "Executable not found: \(executablePath)",
        timedOut: false
      )
    }

    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let termination = DispatchSemaphore(value: 0)

    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.standardOutput = standardOutput
    process.standardError = standardError
    process.terminationHandler = { _ in termination.signal() }

    do {
      try process.run()
    } catch {
      return CommandResult(
        status: -1,
        standardOutput: "",
        standardError: error.localizedDescription,
        timedOut: false
      )
    }

    let didTimeOut = termination.wait(timeout: .now() + timeout) == .timedOut
    if didTimeOut {
      process.terminate()
      if termination.wait(timeout: .now() + 0.25) == .timedOut {
        kill(process.processIdentifier, SIGKILL)
        _ = termination.wait(timeout: .now() + 0.25)
      }
    }

    let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let errorData = standardError.fileHandleForReading.readDataToEndOfFile()

    return CommandResult(
      status: didTimeOut ? -1 : process.terminationStatus,
      standardOutput: String(decoding: outputData, as: UTF8.self),
      standardError: String(decoding: errorData, as: UTF8.self),
      timedOut: didTimeOut
    )
  }
}

// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "DDCVolumeKeys",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .executable(name: "DDCVolumeKeys", targets: ["DDCVolumeKeys"]),
    .executable(
      name: "DDCVolumeKeysVerification",
      targets: ["DDCVolumeKeysVerification"]
    ),
  ],
  targets: [
    .target(name: "DDCVolumeKeysCore", path: "Sources/DDCVolumeKeys"),
    .executableTarget(
      name: "DDCVolumeKeys",
      dependencies: ["DDCVolumeKeysCore"],
      path: "Sources/DDCVolumeKeysApp"
    ),
    .executableTarget(
      name: "DDCVolumeKeysVerification",
      dependencies: ["DDCVolumeKeysCore"],
      path: "Sources/DDCVolumeKeysVerification"
    ),
  ],
  swiftLanguageModes: [.v5]
)

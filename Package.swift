// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "time-kit",
  platforms: [ .macOS(.v15) ],
  products: [
    .library( name: "TimeKit", targets: ["TimeKit"] ),
  ],
  traits: [
    .trait(name: "DistributedTracingSupport"),
    .default(enabledTraits: ["DistributedTracingSupport"] )
  ],
  dependencies: [
    .package(url: "https://github.com/bwdmr/error-kit.git", branch: "feat_branch_four"),
    .package(url: "https://github.com/apple/swift-distributed-tracing", from: "1.3.1"),
    .package(url: "https://github.com/apple/swift-service-context", from: "1.2.1")
  ],
  targets: [
    .target(
      name: "CTimeKit",
      dependencies: [],
      publicHeadersPath: "include",
      cSettings: [ .headerSearchPath(".") ],
      swiftSettings: [ .interoperabilityMode(.C) ]
    ),
    .target(
      name: "TimeKit",
      dependencies: [
        "CTimeKit",
        .product(name: "ErrorKit", package: "error-kit"),
        .product(name: "ServiceContextModule", package: "swift-service-context"),
        .product(name: "Tracing", package: "swift-distributed-tracing", condition: .when(traits: ["DistributedTracingSupport"])),
      ],
      swiftSettings: [ .enableUpcomingFeature("StrictConcurrency") ]
    ),
    .testTarget(
      name: "TimeKitTests",
      dependencies: [
        "TimeKit",
        .product(name: "InMemoryTracing", package: "swift-distributed-tracing", condition: .when(traits: ["DistributedTracingSupport"])),
      ]
    ),
  ]
)

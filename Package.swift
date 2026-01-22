// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "time-kit",
    platforms: [ .macOS(.v15) ],
    products: [ .library( name: "TimeKit", targets: ["TimeKit"]) ],
    targets: [
        .target(name: "TimeKit"),
        .testTarget(name: "TimeKitTests", dependencies: [.target(name: "TimeKit")]),
    ]
)

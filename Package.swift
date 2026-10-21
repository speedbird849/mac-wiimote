// swift-tools-version: 6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MacWiimote",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "MacWiimote",
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreHID")
            ]
        ),
        .testTarget(
            name: "MacWiimoteTests",
            dependencies: ["MacWiimote"]
        ),
    ]
)

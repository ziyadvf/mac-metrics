// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacMetrics",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacMetrics", targets: ["MacMetrics"])
    ],
    targets: [
        .executableTarget(
            name: "MacMetrics",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)

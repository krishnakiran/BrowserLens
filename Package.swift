// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BrowserLens",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "BrowserLens", targets: ["BrowserLens"]),
        .executable(name: "BrowserLensSelfTest", targets: ["BrowserLensSelfTest"])
    ],
    targets: [
        .target(
            name: "BrowserLensCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "BrowserLens",
            dependencies: ["BrowserLensCore"],
            path: "Sources/BrowserLensApp"
        ),
        .executableTarget(
            name: "BrowserLensSelfTest",
            dependencies: ["BrowserLensCore"],
            path: "Tools/BrowserLensSelfTest"
        )
    ]
)

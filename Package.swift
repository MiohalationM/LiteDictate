// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LiteDictate",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "LiteDictateCore",
            targets: ["LiteDictateCore"]
        ),
        .executable(
            name: "LiteDictateApp",
            targets: ["LiteDictateApp"]
        ),
    ],
    targets: [
        .target(
            name: "CLiteDictateAtomics",
            path: "Sources/CLiteDictateAtomics",
            publicHeadersPath: "include"
        ),
        .target(
            name: "CLiteDictateAudio",
            path: "Sources/CLiteDictateAudio",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate"),
            ]
        ),
        .target(
            name: "LiteDictateCore",
            dependencies: [
                "CLiteDictateAtomics",
                "CLiteDictateAudio",
            ],
            path: "Sources/LiteDictateCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(
            name: "LiteDictateApp",
            dependencies: [
                "LiteDictateCore",
            ],
            path: "Sources/LiteDictateApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
            ]
        ),
        .testTarget(
            name: "LiteDictateCoreTests",
            dependencies: ["LiteDictateCore"],
            path: "Tests/LiteDictateCoreTests"
        ),
        .testTarget(
            name: "LiteDictateAudioTests",
            dependencies: ["LiteDictateCore", "CLiteDictateAudio"],
            path: "Tests/LiteDictateAudioTests"
        ),
        .testTarget(
            name: "LiteDictateInputTests",
            dependencies: ["LiteDictateCore"],
            path: "Tests/LiteDictateInputTests"
        ),
    ],
    cLanguageStandard: .c11
)

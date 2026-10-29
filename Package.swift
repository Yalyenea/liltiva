// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Command Line Tools (no Xcode) ship Testing.framework outside the default
// search paths. Opt in with KUMONE_CLT_TESTING=1 to wire it up so `swift test`
// works there; leave it unset with Xcode (and in CI), where these flags are
// unnecessary.
//
// After a full .build wipe on a CLT-only machine, `swift test` needs a
// two-phase dance (SPM's derived runner compiles without these settings, so
// its canImport(Testing) fails and it silently runs 0 tests; but exposing
// the swiftmodule during the test-target compile kills the framework
// autolink and the link fails with undefined Testing symbols):
//   1. Build once (KUMONE_CLT_TESTING=1 swift build --build-tests) with NO
//      Testing.swiftmodule symlink present, so the test objects compile
//      against the framework (autolink intact).
//   2. ln -sfn "$CLT/Frameworks/Testing.framework/Versions/A/Modules/\
//      Testing.swiftmodule" .build/arm64-apple-macosx/debug/Modules/ ,
//      rm -rf .build/arm64-apple-macosx/debug/LiltivaPackageTests.derived ,
//      then KUMONE_CLT_TESTING=1 swift test — the runner regenerates with
//      Testing visible while the cached test objects keep their autolink
//      records.
let cltDeveloperDir = "/Library/Developer/CommandLineTools/Library/Developer"
let cltHasTesting = ProcessInfo.processInfo.environment["KUMONE_CLT_TESTING"] == "1"
let cltTestingSwiftSettings: [SwiftSetting] = cltHasTesting
    ? [.unsafeFlags(["-F", cltDeveloperDir + "/Frameworks"])]
    : []
let cltTestingLinkerSettings: [LinkerSetting] = cltHasTesting
    ? [.unsafeFlags([
        "-F", cltDeveloperDir + "/Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", cltDeveloperDir + "/Frameworks",
        "-Xlinker", "-rpath", "-Xlinker", cltDeveloperDir + "/usr/lib",
    ])]
    : []

let package = Package(
    name: "Liltiva",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "Liltiva", targets: ["KumoneLauncher"]),
        .library(name: "KumoneCore", targets: ["KumoneCore"]),
    ],
    targets: [
        .target(
            name: "KumoneCore",
            dependencies: [
                "KumoneObjC",
            ],
            path: "Sources/Kumone",
            exclude: ["Resources"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        // Objective-C exception catching for the playback engine (macOS only):
        // AVFAudio reports some failures as NSExceptions Swift cannot catch.
        .target(
            name: "KumoneObjC",
            path: "Sources/KumoneObjC",
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .executableTarget(
            name: "KumoneLauncher",
            dependencies: [
                "KumoneCore",
            ],
            path: "Sources/KumoneLauncher",
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "KumoneCoreTests",
            dependencies: [
                "KumoneCore",
                "KumoneObjC",
            ],
            path: "Tests/KumoneCoreTests",
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ] + cltTestingSwiftSettings,
            linkerSettings: cltTestingLinkerSettings
        ),
    ],
    cxxLanguageStandard: .cxx17
)

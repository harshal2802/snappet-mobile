// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HighlightEngine",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "HighlightEngine", targets: ["HighlightEngine"]),
    ],
    targets: [
        // Pure Swift, ZERO platform dependencies (no HealthKit / AVFoundation /
        // UIKit). This is the swappable algorithm core — it must stay portable so
        // it can run on iOS, watchOS, in tests, and later be reused on Android via
        // a port or shared spec. Keep platform I/O OUT of this target.
        .target(name: "HighlightEngine"),
        .testTarget(name: "HighlightEngineTests", dependencies: ["HighlightEngine"],
                    resources: [.copy("Fixtures/synthetic-feedback.jsonl")]),
    ]
)

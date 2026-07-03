// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Marquee",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Marquee",
            path: "Marquee"
            // NOTE: no -parse-as-library. The entry point is Marquee/App/main.swift (top-level code),
            // which must run BEFORE SwiftUI's App bootstrap to clear SwiftUI's persisted window frame.
            // -parse-as-library forbids top-level code and forces @main, so it is intentionally omitted.
        )
    ]
)

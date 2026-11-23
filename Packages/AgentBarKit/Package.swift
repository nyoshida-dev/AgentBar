// swift-tools-version: 6.2
import PackageDescription

// Everything that is not UI: models, readers, the snapshot codec. The app target, the widget
// extension and the tests all depend on it, and `swift test` runs it headless.
let package = Package(
    name: "AgentBarKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentBarKit", targets: ["AgentBarKit"]),
    ],
    targets: [
        .target(
            name: "AgentBarKit",
            dependencies: [
                // macOS imports SQLite3 from the SDK. Linux has the library and no module,
                // so the system target below supplies one. It is not built on macOS.
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            pkgConfig: "sqlite3",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .testTarget(
            name: "AgentBarKitTests",
            dependencies: ["AgentBarKit"],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)

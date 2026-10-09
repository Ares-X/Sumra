// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sumra", defaultLocalization: "en", platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CArchive", linkerSettings: [.linkedLibrary("archive")]),
        .target(name: "SumraCore", dependencies: ["CArchive"]),
        .testTarget(name: "SumraCoreTests", dependencies: ["SumraCore"])
    ]
)

#if os(macOS)
package.products = [.executable(name: "Sumra", targets: ["Sumra"])]
package.dependencies = [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6")]
package.targets += [
        .executableTarget(name: "Sumra", dependencies: ["SumraCore", .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))],
                          resources: [.copy("Resources/Reader"), .copy("Resources/Localizations")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"], .when(platforms: [.macOS]))]),
        .testTarget(name: "SumraAppTests", dependencies: ["Sumra"])
]
#endif

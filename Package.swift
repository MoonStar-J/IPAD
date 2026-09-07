// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YeobaekChecks",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CoreChecks", targets: ["CoreChecks"])],
    targets: [
        .executableTarget(name: "CoreChecks", path: ".", exclude: [
            "Yeobaek/App", "Yeobaek/Canvas", "Yeobaek/Views", "Yeobaek/Services",
            "Yeobaek/Assets.xcassets", "Yeobaek/Info.plist", "Yeobaek/PrivacyInfo.xcprivacy",
            "Yeobaek.xcodeproj", "scripts", "README.md", "QA.md"
        ], sources: ["Yeobaek/Core", "Tests/CoreChecks"])
    ]
)

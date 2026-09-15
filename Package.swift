// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NoteMarginChecks",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "CoreChecks", targets: ["CoreChecks"])],
    targets: [
        .executableTarget(name: "CoreChecks", path: ".", exclude: [
            "NoteMargin/App", "NoteMargin/Canvas", "NoteMargin/Views", "NoteMargin/Services",
            "NoteMargin/Assets.xcassets", "NoteMargin/Info.plist", "NoteMargin/PrivacyInfo.xcprivacy",
            "NoteMargin/PersonalResources", "NoteMargin/ko.lproj", "NoteMargin/en.lproj",
            "NoteMargin.xcodeproj", "scripts", "docs", "README.md", "QA.md"
        ], sources: ["NoteMargin/Core", "Tests/CoreChecks"])
    ]
)

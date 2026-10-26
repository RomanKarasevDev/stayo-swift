// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Stayo",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "Stayo", targets: ["Stayo"]), .executable(name: "stayo-example", targets: ["StayoExample"])],
    targets: [.target(name: "Stayo"), .executableTarget(name: "StayoExample", dependencies: ["Stayo"]), .testTarget(name: "StayoTests", dependencies: ["Stayo"], exclude: ["Fixtures"])]
)

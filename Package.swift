// swift-tools-version: 5.9
import PackageDescription

var products: [Product] = []
var targets: [Target] = [
    .target(name: "CleanerCore", path: "macOS/CleanerCore"),
    .testTarget(name: "CleanerCoreTests", dependencies: ["CleanerCore"], path: "macOS/Tests"),
]

#if os(macOS)
products.append(.executable(name: "FluentCleaner", targets: ["FluentCleanerApp"]))
targets.append(.executableTarget(name: "FluentCleanerApp", dependencies: ["CleanerCore"], path: "macOS/App"))
#endif

let package = Package(
    name: "FluentCleaner",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)

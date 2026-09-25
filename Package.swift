// swift-tools-version: 6.0
// THROWAWAY local test manifest — NOT committed. Exists only so `swift test`
// can run the Domain/Infrastructure suites when tuist generate is unavailable
// (sandboxed sessions cannot write the clang module cache under /var/folders).
// The source of truth for the project graph remains Project.swift (Tuist).
import PackageDescription

let package = Package(
    name: "ClaudeBar-ThrowawayTests",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/Kolos65/Mockable.git", from: "0.5.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.12.0"),
        .package(url: "https://github.com/awslabs/aws-sdk-swift", exact: "1.6.99"),
    ],
    targets: [
        .target(
            name: "Domain",
            dependencies: [
                .product(name: "Mockable", package: "Mockable"),
            ],
            path: "Sources/Domain"
        ),
        .target(
            name: "Infrastructure",
            dependencies: [
                .target(name: "Domain"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Mockable", package: "Mockable"),
                .product(name: "AWSCloudWatch", package: "aws-sdk-swift"),
                .product(name: "AWSPricing", package: "aws-sdk-swift"),
                .product(name: "AWSSDKIdentity", package: "aws-sdk-swift"),
            ],
            path: "Sources/Infrastructure",
            // SweetCookieKit requires swift-tools 6.2 (toolchain unavailable locally);
            // these providers are wired only from the App layer, so the throwaway
            // test build excludes them instead of resolving that dependency.
            // KimiUsageProbe depends on KimiTokenProvider, so it is excluded too.
            exclude: [
                "Alibaba/AlibabaBrowserCookieProvider.swift",
                "Kimi/KimiTokenProvider.swift",
                "Kimi/KimiUsageProbe.swift",
            ]
        ),
        .testTarget(
            name: "DomainTests",
            dependencies: [
                .target(name: "Domain"),
                .product(name: "Mockable", package: "Mockable"),
            ],
            path: "Tests/DomainTests"
        ),
        .testTarget(
            name: "InfrastructureTests",
            dependencies: [
                .target(name: "Domain"),
                .target(name: "Infrastructure"),
                .product(name: "Mockable", package: "Mockable"),
            ],
            path: "Tests/InfrastructureTests"
        ),
    ]
)

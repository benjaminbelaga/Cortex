import ProjectDescription

let project = Project(
    name: "Cortex",
    options: .options(
        defaultKnownRegions: ["en"],
        developmentRegion: "en"
    ),
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "CORTEX_GIT_SHA": "unknown",
            "CORTEX_BUILD_UTC": "unknown",
            "CORTEX_GIT_DIRTY": "true",
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
            "ENABLE_DEBUG_DYLIB": "YES",
        ],
        debug: [
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG MOCKING",
            "ENABLE_DEBUG_DYLIB": "YES",
        ],
        release: [
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "MOCKING",
        ]
    ),
    targets: [
        // MARK: - Domain Layer
        .target(
            name: "Domain",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "fr.yoyaku.cortex.domain",
            deploymentTargets: .macOS("15.0"),
            sources: [
                "Sources/Domain/**/*.swift",
                "Sources/Domain/Provider/ModelAbbreviation.generated.json",
            ],
            dependencies: [
                .external(name: "Mockable"),
            ],
            // ModelAbbreviation.generated.json is committed at the same path as
            // ModelAbbreviation.swift (above) so the build picks it up. After
            // editing `~/repos/llm-router/config/providers.yaml#display_abbreviations`
            // run `scripts/regen-model-abbrev.sh` and rebuild — Tuist's 4.204.0
            // ProjectDescription doesn't expose a public TargetScript factory
            // (verified 2026-08-29: only `init(from:)` is public), so an inline
            // preBuildScript is not available in this Tuist version. The
            // regen script is a one-liner; see scripts/regen-model-abbrev.sh.
            settings: .settings(
                base: [
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                ]
            )
        ),

        // MARK: - Infrastructure Layer
        .target(
            name: "Infrastructure",
            destinations: .macOS,
            product: .staticFramework,
            bundleId: "fr.yoyaku.cortex.infrastructure",
            deploymentTargets: .macOS("15.0"),
            sources: ["Sources/Infrastructure/**"],
            dependencies: [
                .target(name: "Domain"),
                .external(name: "Mockable"),
                .external(name: "SwiftTerm"),
                .external(name: "AWSCloudWatch"),
                .external(name: "AWSSTS"),
                .external(name: "AWSPricing"),
                .external(name: "AWSSDKIdentity"),
                .external(name: "AWSSSO"),
                .external(name: "AWSSSOOIDC"),
                .external(name: "SweetCookieKit"),
                .external(name: "Subprocess"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                ]
            )
        ),

        // MARK: - Main Application
        .target(
            name: "Cortex",
            destinations: .macOS,
            product: .app,
            bundleId: "fr.yoyaku.cortex",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .file(path: "Sources/App/Info.plist"),
            sources: ["Sources/App/**"],
            resources: [
                "Sources/App/Resources/**",
            ],
            entitlements: .file(path: "Sources/App/entitlements.plist"),
            dependencies: [
                .target(name: "Domain"),
                .target(name: "Infrastructure"),
                .external(name: "Sparkle"),
                .external(name: "MenuBarExtraAccess"),
                .external(name: "Matrix"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_STRICT_CONCURRENCY": "complete",
                    "ENABLE_DEBUG_DYLIB": "YES",
                    "ENABLE_PREVIEWS": "YES",
                    "CODE_SIGN_IDENTITY": "-",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    // Rebrand → "Cortex" (Ben 2026-08-24). The Tuist target keeps
                    // its internal name "Cortex" (so schemes / Package.swift /
                    // CI / `tuist build Cortex` are untouched), but the shipped
                    // product is Cortex.app. Bundle id migrated to fr.yoyaku.cortex
                    // in E4 with non-destructive Keychain/UserDefaults migration
                    // (KeychainServiceMigrator + UserDefaults domain copy);
                    // feed/key rotation happens with the Sparkle keypair (T4 Ben gesture).
                    "PRODUCT_NAME": "Cortex",
                    // Keep the Swift module name "Cortex" (PRODUCT_NAME would
                    // otherwise rename it too) so `@testable import Cortex` in
                    // AppTests and the workspace/scheme identity stay untouched.
                    // Module name is compile-time only, invisible to users.
                    "PRODUCT_MODULE_NAME": "Cortex",
                ],
                debug: [
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG ENABLE_SPARKLE",
                ],
                release: [
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "ENABLE_SPARKLE",
                    // Stable signing for the installed app (Ben 2026-09-23): an
                    // ad-hoc signature pins Keychain trust to the binary cdhash,
                    // so every rebuild re-prompted for every stored key. A
                    // team certificate keeps the designated requirement stable.
                    "CODE_SIGN_IDENTITY": "Developer ID Application",
                    "DEVELOPMENT_TEAM": "YZYJJPX484",
                    "CODE_SIGN_STYLE": "Manual",
                ]
            )
        ),

        // MARK: - Domain Tests
        .target(
            name: "DomainTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "fr.yoyaku.cortex.domain-tests",
            deploymentTargets: .macOS("15.0"),
            sources: ["Tests/DomainTests/**"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "Infrastructure"),
                .external(name: "Mockable"),
                .external(name: "AWSCloudWatch"),
                .external(name: "AWSSTS"),
                .external(name: "AWSPricing"),
                .external(name: "AWSSDKIdentity"),
                .external(name: "AWSSSO"),
                .external(name: "AWSSSOOIDC"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "MOCKING",
                ]
            )
        ),

        // MARK: - Infrastructure Tests
        .target(
            name: "InfrastructureTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "fr.yoyaku.cortex.infrastructure-tests",
            deploymentTargets: .macOS("15.0"),
            sources: ["Tests/InfrastructureTests/**"],
            dependencies: [
                .target(name: "Infrastructure"),
                .target(name: "Domain"),
                .external(name: "Mockable"),
                .external(name: "AWSCloudWatch"),
                .external(name: "AWSSTS"),
                .external(name: "AWSPricing"),
                .external(name: "AWSSDKIdentity"),
                .external(name: "AWSSSO"),
                .external(name: "AWSSSOOIDC"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "MOCKING",
                ]
            )
        ),

        // MARK: - Application Tests
        .target(
            name: "AppTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "fr.yoyaku.cortex.app-tests",
            deploymentTargets: .macOS("15.0"),
            sources: ["Tests/AppTests/**"],
            dependencies: [
                .target(name: "Cortex"),
                .target(name: "Domain"),
                .target(name: "Infrastructure"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "MOCKING",
                    // The app target keeps its internal name "Cortex" but ships
                    // as Cortex.app (PRODUCT_NAME=Cortex), so the auto-derived test
                    // host leaf (target name) points at a non-existent executable.
                    // Pin it to the real Cortex executable.
                    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/Cortex.app/Contents/MacOS/Cortex",
                    "BUNDLE_LOADER": "$(TEST_HOST)",
                ]
            )
        ),

        // MARK: - Acceptance Tests (BDD - Outer Loop)
        .target(
            name: "AcceptanceTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "fr.yoyaku.cortex.acceptance-tests",
            deploymentTargets: .macOS("15.0"),
            sources: ["Tests/AcceptanceTests/**"],
            dependencies: [
                .target(name: "Domain"),
                .target(name: "Infrastructure"),
                .external(name: "Mockable"),
                .external(name: "AWSCloudWatch"),
                .external(name: "AWSSTS"),
                .external(name: "AWSPricing"),
                .external(name: "AWSSDKIdentity"),
                .external(name: "AWSSSO"),
                .external(name: "AWSSSOOIDC"),
            ],
            settings: .settings(
                base: [
                    "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "MOCKING",
                ]
            )
        ),
    ],
    schemes: [
        .scheme(
            name: "Cortex",
            shared: true,
            buildAction: .buildAction(targets: ["Cortex"]),
            testAction: .targets(
                [
                    .testableTarget(target: .target("AcceptanceTests")),
                    .testableTarget(target: .target("DomainTests")),
                    .testableTarget(target: .target("InfrastructureTests")),
                    .testableTarget(target: .target("AppTests")),
                ],
                configuration: .debug
            ),
            runAction: .runAction(configuration: .debug, executable: .target("Cortex")),
            archiveAction: .archiveAction(configuration: .release),
            profileAction: .profileAction(configuration: .release, executable: .target("Cortex")),
            analyzeAction: .analyzeAction(configuration: .debug)
        ),
    ]
)

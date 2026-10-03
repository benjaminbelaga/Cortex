import Foundation
import Domain

/// Errors raised by `ScriptProbe` *before* an extension probe is allowed to run.
///
/// Kept as its own type rather than a `ProbeError` case: these failures happen
/// before the script executes, so there is no exit code, no stdout and no CLI to
/// attribute the failure to. The message is written for the user and names the
/// manifest field *labels* (never the raw ids), so it maps straight onto a
/// Settings row the user can act on.
public enum ExtensionProbeError: Error, Sendable, Equatable, LocalizedError {
    /// One or more `required` config fields have neither a stored value nor a
    /// `default`, so the probe was not run. `fields` holds the human-readable
    /// labels of the missing fields, in manifest order.
    case unconfigured(fields: [String])

    public var errorDescription: String? {
        switch self {
        case .unconfigured(let fields):
            let noun = fields.count == 1 ? "field" : "fields"
            return "Extension not configured — set the required \(noun) in Settings: \(fields.joined(separator: ", "))."
        }
    }
}

/// A UsageProbe that executes an external script and parses its JSON output.
/// Used by extension providers to probe custom data sources.
public final class ScriptProbe: UsageProbe, @unchecked Sendable {
    private let scriptPath: String
    private let extensionDir: URL
    private let providerId: String
    private let sectionType: SectionType
    private let timeout: TimeInterval
    private let cliExecutor: CLIExecutor
    private let configRepository: (any ExtensionConfigRepository)?
    private let manifest: ExtensionManifest?

    public init(
        scriptPath: String,
        extensionDir: URL,
        providerId: String,
        sectionType: SectionType,
        timeout: TimeInterval = 10,
        cliExecutor: CLIExecutor? = nil,
        configRepository: (any ExtensionConfigRepository)? = nil,
        manifest: ExtensionManifest? = nil
    ) {
        self.scriptPath = scriptPath
        self.extensionDir = extensionDir
        self.providerId = providerId
        self.sectionType = sectionType
        self.timeout = timeout
        self.cliExecutor = cliExecutor ?? DefaultCLIExecutor()
        self.configRepository = configRepository
        self.manifest = manifest
    }

    public func probe() async throws -> UsageSnapshot {
        let command = try buildCommand()

        let result = try await cliExecutor.execute(
            binary: "/bin/sh",
            args: ["-c", command],
            input: nil,
            timeout: timeout,
            workingDirectory: extensionDir,
            autoResponses: [:]
        )

        guard result.exitCode == 0 else {
            throw ProbeError.executionFailed("Extension probe '\(scriptPath)' exited with code \(result.exitCode): \(result.output)")
        }

        guard let data = result.output.data(using: .utf8) else {
            throw ProbeError.parseFailed("Extension probe output is not valid UTF-8")
        }

        let sectionData = try SectionData.decode(from: data, type: sectionType, providerId: providerId)
        return sectionDataToSnapshot(sectionData)
    }

    public func isAvailable() async -> Bool {
        let resolvedPath = resolveScriptPath()
        return FileManager.default.fileExists(atPath: resolvedPath)
    }

    // MARK: - Private

    /// Builds the shell command that runs the probe, prefixing `env VAR=value`
    /// for every configured field.
    ///
    /// A field marked `required` that has no stored value and no `default` is a
    /// hard stop, not a silent omission: the probe is never run without a key it
    /// declared it needs. Running anyway would either fail deep inside the script
    /// (an opaque error attributed to the wrong layer) or, worse, succeed while
    /// quietly returning less data — exactly the silent-failure path this UI is
    /// built to avoid (see `HonestStates`). So instead of dropping the key we
    /// throw `ExtensionProbeError.unconfigured`, naming the missing fields by
    /// label so Settings can point the user at them. Optional fields keep the old
    /// behaviour and are simply left out of the environment.
    private func buildCommand() throws -> String {
        let resolvedPath = resolveScriptPath()

        guard let configRepository, let manifest, !manifest.configFields.isEmpty else {
            return resolvedPath
        }

        let values = configRepository.allValues(forExtensionId: manifest.id, fields: manifest.configFields)

        // `allValues` already folds a field's `default` in over its stored value,
        // so a key that is absent, or present but empty, is a genuinely unset
        // required field.
        let missingRequired = manifest.configFields
            .filter { $0.required && (values[$0.id]?.isEmpty ?? true) }
            .map(\.label)
        guard missingRequired.isEmpty else {
            throw ExtensionProbeError.unconfigured(fields: missingRequired)
        }

        guard !values.isEmpty else {
            return resolvedPath
        }

        // Build "env VAR1=val1 VAR2=val2 ./probe.sh" command
        let envPairs = manifest.configFields.compactMap { field -> String? in
            guard let value = values[field.id] else { return nil }
            let escaped = value.replacingOccurrences(of: "'", with: "'\\''")
            return "\(field.environmentVariableName)='\(escaped)'"
        }

        return "env \(envPairs.joined(separator: " ")) \(resolvedPath)"
    }

    private func resolveScriptPath() -> String {
        if scriptPath.hasPrefix("/") {
            return scriptPath
        }
        return extensionDir.appending(path: scriptPath).path()
    }

    private func sectionDataToSnapshot(_ data: SectionData) -> UsageSnapshot {
        switch data {
        case .quotas(let quotas):
            return UsageSnapshot(providerId: providerId, quotas: quotas, capturedAt: Date())
        case .cost(let costUsage):
            return UsageSnapshot(providerId: providerId, quotas: [], capturedAt: Date(), costUsage: costUsage)
        case .daily(let report):
            return UsageSnapshot(providerId: providerId, quotas: [], capturedAt: Date(), dailyUsageReport: report)
        case .metrics(let metrics):
            return UsageSnapshot(providerId: providerId, quotas: [], capturedAt: Date(), extensionMetrics: metrics)
        case .status:
            return UsageSnapshot(providerId: providerId, quotas: [], capturedAt: Date())
        }
    }
}

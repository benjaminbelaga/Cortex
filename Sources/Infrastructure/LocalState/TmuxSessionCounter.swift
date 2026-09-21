import Foundation

/// Counts REAL tmux sessions on the default socket plus explicitly configured
/// extra sockets — the sessions card must show the tmux truth, not
/// transcript-file counts. One probe per popover open, cached 30 s.
///
/// Extra socket names come from settings (`integration.tmuxSocketNames`);
/// the default socket is always counted. No machine-specific socket is
/// hardcoded here — legacy machines seed their socket via migration.
public enum TmuxSessionCounter {
    private actor Cache {
        var entry: (at: Date, value: Int)?

        func get(maxAge: TimeInterval) -> Int? {
            guard let entry, Date().timeIntervalSince(entry.at) < maxAge else { return nil }
            return entry.value
        }

        func set(_ value: Int) {
            entry = (Date(), value)
        }
    }

    private static let cache = Cache()

    public static func count(socketNames: [String] = []) async -> Int {
        if let cached = await cache.get(maxAge: 30) {
            return cached
        }
        let value = await Task.detached(priority: .utility) {
            Self.countSync(socketNames: socketNames)
        }.value
        await cache.set(value)
        return value
    }

    private static func countSync(socketNames: [String]) -> Int {
        var commands = ["tmux ls 2>/dev/null"]
        for name in socketNames where name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil {
            commands.append("tmux -L \(name) ls 2>/dev/null")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", commands.joined(separator: "; ")]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return 0
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").filter { !$0.isEmpty }.count
    }
}

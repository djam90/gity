import Foundation

public struct GitError: LocalizedError, Sendable {
    public let arguments: [String]
    public let exitCode: Int32
    public let standardError: String

    public var errorDescription: String? {
        let message = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            return "git \(arguments.first ?? "") failed with exit code \(exitCode)."
        }
        // Drop git's "fatal: " / "error: " prefixes, they read poorly in alerts.
        return message
            .split(separator: "\n")
            .map { line in
                for prefix in ["fatal: ", "error: "] where line.hasPrefix(prefix) {
                    return String(line.dropFirst(prefix.count))
                }
                return String(line)
            }
            .joined(separator: "\n")
    }
}

public enum GitExecutable {
    /// Homebrew installs are usually newer than the Xcode-provided git, so prefer them.
    public static let candidatePaths = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]

    /// Returns `preferredPath` if it is executable, otherwise the first installed candidate.
    public static func locate(preferredPath: String? = nil) -> URL? {
        let fileManager = FileManager.default
        if let preferredPath, !preferredPath.isEmpty {
            let expanded = (preferredPath as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return candidatePaths
            .first { fileManager.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }
}

/// Runs git as a subprocess. Output is read off the main thread and delivered via async/await.
public struct GitRunner: Sendable {
    public let executableURL: URL
    public let workingDirectory: URL

    public init(executableURL: URL, workingDirectory: URL) {
        self.executableURL = executableURL
        self.workingDirectory = workingDirectory
    }

    static let environment: [String: String] = {
        var environment = ProcessInfo.processInfo.environment
        // Read-only commands like `status` must not take the index lock, otherwise we would
        // race with the user's own git usage (and retrigger our file watcher).
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        // Never block waiting for credentials on a terminal we do not have.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        // Apps launched from Finder get a minimal PATH; hooks and credential helpers expect more.
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (existing + extraPaths.filter { !existing.contains($0) }).joined(separator: ":")
        return environment
    }()

    /// - Parameter successExitCodes: Exit codes treated as success. `git diff --no-index`
    ///   exits with 1 when the files differ, for example.
    @discardableResult
    public func run(_ arguments: [String], successExitCodes: Set<Int32> = [0]) async throws -> Data {
        let executableURL = executableURL
        let workingDirectory = workingDirectory

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.currentDirectoryURL = workingDirectory
                process.environment = Self.environment

                let output = Pipe()
                let error = Pipe()
                process.standardOutput = output
                process.standardError = error
                process.standardInput = FileHandle.nullDevice

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Drain stderr concurrently so a chatty command cannot fill the pipe and deadlock.
                let errorBuffer = DataBuffer()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errorBuffer.data = error.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outputData = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()

                if successExitCodes.contains(process.terminationStatus) {
                    continuation.resume(returning: outputData)
                } else {
                    continuation.resume(throwing: GitError(
                        arguments: arguments,
                        exitCode: process.terminationStatus,
                        standardError: String(decoding: errorBuffer.data, as: UTF8.self)
                    ))
                }
            }
        }
    }

    public func string(_ arguments: [String], successExitCodes: Set<Int32> = [0]) async throws -> String {
        String(decoding: try await run(arguments, successExitCodes: successExitCodes), as: UTF8.self)
    }
}

private final class DataBuffer: @unchecked Sendable {
    var data = Data()
}

import Foundation
import Darwin
import Security

final class HelperRunner {
    private let executableURL: URL
    init(executableURL: URL) { self.executableURL = executableURL }

    func run(_ request: HelperRequest, timeout: TimeInterval = 45) async throws -> HelperResult {
        let input = try JSONEncoder().encode(request)
        guard input.count <= HelperDecoder.maximumRequestBytes else { throw HelperFailure.oversizedRequest }
        let requirement = try validateExecutable()
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executableURL
        process.environment = [:]
        process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw HelperFailure.launch }
        do { try validateRunningProcess(process, requirement: requirement) }
        catch {
            await Self.terminateAndWait(process, stdin: stdin)
            throw error
        }
        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: HelperResult.self) { group in
                group.addTask {
                    do {
                        let writer = stdin.fileHandleForWriting
                        defer { try? writer.close() }
                        try writer.write(contentsOf: input)
                    }
                    var output = Data()
                    while let chunk = try stdout.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                        output.append(chunk)
                        guard output.count <= HelperDecoder.maximumOutputBytes else {
                            throw HelperFailure.oversizedOutput
                        }
                    }
                    while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
                    return try HelperDecoder.decode(output)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    await Self.terminateAndWait(process, stdin: stdin)
                    throw HelperFailure.timeout
                }
                defer {
                    group.cancelAll()
                }
                return try await group.next()!
                }
            } onCancel: {
                Self.requestTermination(process, stdin: stdin)
            }
        } catch {
            await Self.terminateAndWait(process, stdin: stdin)
            throw error
        }
    }

    func launchStreaming(_ request: StreamingHelperRequest) async throws -> StreamingHelperSession {
        var input = try JSONEncoder().encode(request)
        input.append(0x0A)
        guard input.count <= HelperDecoder.maximumRequestBytes else { throw HelperFailure.oversizedRequest }
        let requirement = try validateExecutable()
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--stream"]
        process.environment = [:]
        process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw HelperFailure.launch }
        do {
            try validateRunningProcess(process, requirement: requirement)
            try stdin.fileHandleForWriting.write(contentsOf: input)
        } catch {
            await Self.terminateAndWait(process, stdin: stdin)
            throw error
        }
        return StreamingHelperSession(process: process, stdin: stdin, stdout: stdout)
    }

    fileprivate static func requestTermination(_ process: Process, stdin: Pipe) {
        try? stdin.fileHandleForWriting.close()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if process.isRunning { Darwin.kill(pid, SIGKILL) }
        }
    }

    fileprivate static func terminateAndWait(_ process: Process, stdin: Pipe) async {
        requestTermination(process, stdin: stdin)
        guard process.isRunning else { return }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                while process.isRunning { usleep(10_000) }
                continuation.resume()
            }
        }
    }

    private func validateExecutable() throws -> SecRequirement {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let validationFlags = SecCSFlags(rawValue: UInt32(kSecCSStrictValidate | kSecCSCheckAllArchitectures))
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, validationFlags, nil) == errSecSuccess,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess,
              let requirement else {
            throw HelperFailure.invalidSignature
        }
        if let appURL = Bundle.main.executableURL,
           Self.teamIdentifier(for: code) != Self.teamIdentifier(for: appURL) {
            throw HelperFailure.invalidSignature
        }
        return requirement
    }

    private func validateRunningProcess(_ process: Process, requirement: SecRequirement) throws {
        let attributes = [kSecGuestAttributePid as String: process.processIdentifier] as CFDictionary
        var runningCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &runningCode) == errSecSuccess,
              let runningCode,
              SecCodeCheckValidity(runningCode, [], requirement) == errSecSuccess else {
            throw HelperFailure.invalidSignature
        }
    }

    private static func teamIdentifier(for url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        return teamIdentifier(for: code)
    }

    private static func teamIdentifier(for code: SecStaticCode) -> String? {
        var information: CFDictionary?
        let informationFlags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(code, informationFlags, &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

final class StreamingHelperSession {
    private let process: Process
    private let stdin: Pipe
    private let stdout: Pipe
    private let lock = NSLock()
    private var closed = false

    init(process: Process, stdin: Pipe, stdout: Pipe) {
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
    }

    var isRunning: Bool { process.isRunning }

    func finish(forceRest: Bool, timeout: TimeInterval = 45) async throws -> HelperResult {
        let claimed = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard claimed else { throw HelperFailure.malformedOutput }
        do {
            var finish = try JSONEncoder().encode(StreamingHelperFinish(version: 1, command: "finish", forceRest: forceRest))
            finish.append(0x0A)
            try stdin.fileHandleForWriting.write(contentsOf: finish)
        } catch {
            await HelperRunner.terminateAndWait(process, stdin: stdin)
            throw HelperFailure.streamUnavailableBeforeFinish
        }
        try? stdin.fileHandleForWriting.close()
        do {
            return try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: HelperResult.self) { group in
                group.addTask {
                    var output = Data()
                    while let chunk = try self.stdout.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                        output.append(chunk)
                        guard output.count <= HelperDecoder.maximumOutputBytes else {
                            throw HelperFailure.oversizedOutput
                        }
                    }
                    while self.process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
                    guard self.process.terminationStatus == 0 else { throw HelperFailure.malformedOutput }
                    return try StreamingHelperDecoder.decode(output)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    await HelperRunner.terminateAndWait(self.process, stdin: self.stdin)
                    throw HelperFailure.timeout
                }
                defer {
                    group.cancelAll()
                }
                return try await group.next()!
                }
            } onCancel: {
                HelperRunner.requestTermination(process, stdin: stdin)
            }
        } catch {
            await HelperRunner.terminateAndWait(process, stdin: stdin)
            throw error
        }
    }

    func cancelAndWait() async {
        let claimed = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard claimed else { return }
        await HelperRunner.terminateAndWait(process, stdin: stdin)
    }
}

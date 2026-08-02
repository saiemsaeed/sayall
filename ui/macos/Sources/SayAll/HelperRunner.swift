import Foundation
import Darwin
import Security

actor CompatibilityRegistry {
    private struct InFlight {
        let id: UUID
        let task: Task<HelperRunner.CompatibilityToken, Error>
    }

    private var cached = [String: HelperRunner.CompatibilityToken]()
    private var inFlight = [String: InFlight]()

    func token(for key: String,
               probe: @escaping @Sendable () async throws -> HelperRunner.CompatibilityToken) async throws -> HelperRunner.CompatibilityToken {
        if let token = cached[key] { return token }

        let entry: InFlight
        if let existing = inFlight[key] {
            entry = existing
        } else {
            entry = InFlight(id: UUID(), task: Task { try await probe() })
            inFlight[key] = entry
        }

        do {
            let token = try await entry.task.value
            if inFlight[key]?.id == entry.id {
                cached[key] = token
                inFlight[key] = nil
            }
            return token
        } catch {
            if inFlight[key]?.id == entry.id { inFlight[key] = nil }
            throw error
        }
    }
}

final class HelperRunner {
    struct CompatibilityToken: Sendable {
        let buildVersion: String
        let codeIdentity: Data
    }
    private let executableURL: URL
    private static let compatibilityRegistry = CompatibilityRegistry()
    init(executableURL: URL) { self.executableURL = executableURL }

    func run(_ request: HelperRequest, timeout: TimeInterval = 45) async throws -> HelperResult {
        let input = try JSONEncoder().encode(request)
        guard input.count <= HelperDecoder.maximumRequestBytes else { throw HelperFailure.oversizedRequest }
        let requirement = try validateExecutable()
        let compatibility = try await validateCompatibility(requirement: requirement)
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executableURL
        process.environment = [:]
        process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw HelperFailure.launch }
        do { try validateRunningProcess(process, requirement: requirement, expectedIdentity: compatibility?.codeIdentity) }
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

    func compatibilityPreflight() async throws -> CompatibilityToken? {
        let requirement = try validateExecutable()
        return try await validateCompatibility(requirement: requirement)
    }

    func launchStreaming(_ request: StreamingHelperRequest, compatibility supplied: CompatibilityToken? = nil) async throws -> StreamingHelperSession {
        var input = try JSONEncoder().encode(request)
        input.append(0x0A)
        guard input.count <= HelperDecoder.maximumRequestBytes else { throw HelperFailure.oversizedRequest }
        let requirement = try validateExecutable()
        let compatibility: CompatibilityToken?
        if let supplied {
            guard supplied.buildVersion == Self.expectedBuildVersion else { throw HelperFailure.incompatibleBuild }
            compatibility = supplied
        } else {
            compatibility = try await validateCompatibility(requirement: requirement)
        }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--stream"]
        process.environment = [:]
        process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw HelperFailure.launch }
        do {
            try validateRunningProcess(process, requirement: requirement, expectedIdentity: compatibility?.codeIdentity)
            try stdin.fileHandleForWriting.write(contentsOf: input)
            _ = try await Self.readReady(from: stdout.fileHandleForReading, process: process, stdin: stdin)
        } catch {
            await Self.terminateAndWait(process, stdin: stdin)
            throw error
        }
        return StreamingHelperSession(process: process, stdin: stdin, stdout: stdout)
    }

    private static var expectedBuildVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private func validateCompatibility(requirement: SecRequirement) async throws -> CompatibilityToken? {
        // SwiftPM's test runner has its own synthetic version; production is
        // always an app bundle and must perform the compatibility probe.
        guard Bundle.main.bundleURL.pathExtension == "app",
              let buildVersion = Self.expectedBuildVersion else { return nil }
        let key = executableURL.path + "\u{0}" + buildVersion
        return try await Self.compatibilityRegistry.token(for: key) {
            try await self.probeCompatibility(requirement: requirement, buildVersion: buildVersion)
        }
    }

    private func probeCompatibility(requirement: SecRequirement,
                                    buildVersion: String) async throws -> CompatibilityToken {
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executableURL
        process.arguments = ["--worker-info", "--wait"]
        process.environment = [:]
        process.standardInput = stdin; process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { await Self.terminateAndWait(process, stdin: stdin); throw error }
        do {
            let identity = try validatedRunningCodeIdentity(process, requirement: requirement)
            try await Self.completeCompatibilityProbe(process: process, stdin: stdin, stdout: stdout,
                buildVersion: buildVersion, timeout: 2)
            let token = CompatibilityToken(buildVersion: buildVersion, codeIdentity: identity)
            return token
        } catch { await Self.terminateAndWait(process, stdin: stdin); throw error }
    }

    static func completeCompatibilityProbe(process: Process, stdin: Pipe, stdout: Pipe,
                                           buildVersion: String, timeout: TimeInterval) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        let frame: Data
        do {
            frame = try await readFrame(from: stdout.fileHandleForReading, process: process,
                stdin: stdin, maximum: 4096, timeout: remainingTime(until: deadline))
        } catch {
            if DispatchTime.now().uptimeNanoseconds >= deadline { throw HelperFailure.timeout }
            throw error
        }
        guard process.isRunning,
              let info = try? JSONDecoder().decode(WorkerInfo.self, from: frame),
              info.protocolVersion == 1 else { throw HelperFailure.unsupportedVersion }
        guard info.buildVersion == buildVersion else { throw HelperFailure.incompatibleBuild }
        try? stdin.fileHandleForWriting.close()
        do {
            try await drainAndWait(from: stdout.fileHandleForReading, process: process,
                stdin: stdin, maximum: 4096, timeout: remainingTime(until: deadline))
        } catch {
            if DispatchTime.now().uptimeNanoseconds >= deadline { throw HelperFailure.timeout }
            throw error
        }
    }

    private static func remainingTime(until deadline: UInt64) -> TimeInterval {
        let now = DispatchTime.now().uptimeNanoseconds
        return now < deadline ? TimeInterval(deadline - now) / 1_000_000_000 : 0
    }

    private static func readReady(from handle: FileHandle, process: Process, stdin: Pipe) async throws -> StreamingHelperDecoder.Ready {
        do {
            let data = try await withTaskCancellationHandler {
                try await readFrame(from: handle, process: process, stdin: stdin,
                    maximum: StreamingHelperDecoder.maximumReadyBytes, timeout: 2)
            } onCancel: {
                requestTermination(process, stdin: stdin)
            }
            guard process.isRunning else { throw HelperFailure.streamUnavailableBeforeFinish }
            return try StreamingHelperDecoder.decodeReady(data)
        } catch {
            await terminateAndWait(process, stdin: stdin)
            throw HelperFailure.streamUnavailableBeforeFinish
        }
    }

    private static func readFrame(from handle: FileHandle, process: Process, stdin: Pipe,
                                  maximum: Int, timeout: TimeInterval) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var data = Data()
                while let byte = try handle.read(upToCount: 1), !byte.isEmpty {
                    if byte[0] == 0x0A { return data }
                    data.append(byte)
                    if data.count > maximum { throw HelperFailure.oversizedOutput }
                }
                throw HelperFailure.malformedOutput
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                await terminateAndWait(process, stdin: stdin)
                throw HelperFailure.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func drainAndWait(from handle: FileHandle, process: Process, stdin: Pipe,
                                     maximum: Int, timeout: TimeInterval) async throws {
        let output = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                var data = Data()
                while let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
                    data.append(chunk)
                    guard data.count <= maximum + 1 else { throw HelperFailure.oversizedOutput }
                }
                while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
                guard process.terminationStatus == 0 else { throw HelperFailure.unsupportedVersion }
                return data
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                await terminateAndWait(process, stdin: stdin)
                throw HelperFailure.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        guard output.isEmpty else { throw HelperFailure.malformedOutput }
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

    private func validateRunningProcess(_ process: Process, requirement: SecRequirement, expectedIdentity: Data?) throws {
        let attributes = [kSecGuestAttributePid as String: process.processIdentifier] as CFDictionary
        var runningCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &runningCode) == errSecSuccess,
              let runningCode,
              SecCodeCheckValidity(runningCode, [], requirement) == errSecSuccess else {
            throw HelperFailure.invalidSignature
        }
        if let expectedIdentity, try codeIdentity(runningCode) != expectedIdentity {
            throw HelperFailure.invalidSignature
        }
    }

    private func validatedRunningCodeIdentity(_ process: Process, requirement: SecRequirement) throws -> Data {
        let attributes = [kSecGuestAttributePid as String: process.processIdentifier] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else {
            throw HelperFailure.invalidSignature
        }
        return try codeIdentity(code)
    }

    private func codeIdentity(_ code: SecCode) throws -> Data {
        var information: CFDictionary?
        // SecCode and SecStaticCode are CF wrappers around the same Code object;
        // the C API accepts either, but Swift imports this parameter narrowly.
        let signingCode = unsafeBitCast(code, to: SecStaticCode.self)
        guard SecCodeCopySigningInformation(signingCode, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identity = values[kSecCodeInfoUnique as String] as? Data else { throw HelperFailure.invalidSignature }
        return identity
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

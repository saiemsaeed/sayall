import XCTest
import AppKit
import ApplicationServices
import Darwin
@testable import SayAll
@testable import SayAllCLI
import SayAllControl

final class CLIFoundationTests: XCTestCase {
    func testOnlyFoundationCommandsParse() throws {
        XCTAssertEqual(try CLI.parse(["version"]), .version)
        XCTAssertEqual(try CLI.parse(["--version"]), .version)
        XCTAssertEqual(try CLI.parse(["status"]), .status)
        XCTAssertEqual(try CLI.parse(["toggle"]), .toggle)
        XCTAssertEqual(try CLI.parse(["config", "init"]), .configInit)
        XCTAssertThrowsError(try CLI.parse(["start"]))
        XCTAssertThrowsError(try CLI.parse(["stop"]))
    }

    func testConfigInitIsPrivateValidAndNeverOverwrites() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let url = try CLI.initializeConfig(home: home, environment: [:])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let stt = json?["stt"] as? [String: Any]
        let recording = json?["recording"] as? [String: Any]
        let metrics = json?["metrics"] as? [String: Any]
        XCTAssertEqual(stt?["api_key"] as? String, "")
        XCTAssertEqual(stt?["model"] as? String, "nova-3")
        XCTAssertEqual(recording?["max_seconds"] as? Int, 300)
        XCTAssertEqual(recording?["min_ms"] as? Int, 300)
        XCTAssertEqual(metrics?["history_max_entries"] as? Int, 1_000)
        XCTAssertEqual(json?["notifications"] as? Bool, true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let original = try Data(contentsOf: url)
        XCTAssertThrowsError(try CLI.initializeConfig(home: home, environment: [:]))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testConfigInitUsesTheSameXDGPathAsTheAppLoader() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let xdg = home.appendingPathComponent("custom-config")
        let environment = ["XDG_CONFIG_HOME": xdg.path]
        let url = try CLI.initializeConfig(home: home, environment: environment)
        XCTAssertEqual(url, ConfigurationLoader(environment: environment, homeDirectory: home).url)
    }

    func testControlProtocolRoundTripsStableState() throws {
        let response = ControlResponse(ok: false, state: "processing", error: "busy: SayAll is processing")
        XCTAssertEqual(try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response)), response)
    }

    func testControlFrameUsesOneAbsoluteDeadline() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        var noPipe: Int32 = 1
        setsockopt(descriptors[1], SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        let writer = descriptors[1]
        let writerFinished = DispatchGroup()
        writerFinished.enter()
        DispatchQueue.global().async {
            defer { writerFinished.leave() }
            for value in "{{{{".utf8 {
                var byte = value
                _ = withUnsafePointer(to: &byte) { write(writer, $0, 1) }
                Thread.sleep(forTimeInterval: 0.08)
            }
        }
        let started = Date()
        XCTAssertThrowsError(try ControlSocket.readLine(from: descriptors[0],
            deadline: ControlSocket.deadline(afterMilliseconds: 150)))
        let elapsed = Date().timeIntervalSince(started)
        writerFinished.wait()
        XCTAssertLessThan(elapsed, 0.3)
    }
}

final class StateMachineTests: XCTestCase {
    func testLegalRecordingPipeline() throws {
        var sut = StateMachine()
        for state in [DictationState.recording, .stopping, .processing, .delivering, .success, .idle] { try sut.transition(to: state) }
        XCTAssertEqual(sut.state, .idle)
    }
    func testIllegalTransitionsDoNotMutate() {
        var sut = StateMachine()
        XCTAssertThrowsError(try sut.transition(to: .processing))
        XCTAssertEqual(sut.state, .idle)
    }
    func testSuccessfulDeliveryCanHideImmediately() throws {
        var sut = StateMachine()
        for state in [DictationState.recording, .stopping, .processing, .delivering, .idle] {
            try sut.transition(to: state)
        }
        XCTAssertEqual(sut.state, .idle)
    }
}

final class TextDeliveryTests: XCTestCase {
    @MainActor
    func testCopyReturnsSuccessAndWritesExactText() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pro.leets.sayall.tests.\(UUID().uuidString)"))
        let text = "SayAll delivery test 👋\nsecond line"

        XCTAssertTrue(TextDelivery.copy(text, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), text)
    }

    @MainActor
    func testUnchangedEditableTargetPostsPasteAfterCopying() {
        let element = AXUIElementCreateApplication(101)
        let focus = focus(pid: 101, element: element)
        var posted = 0
        let client = accessibilityClient(focus: { focus }, post: { posted += 1; return true })
        let target = TextDelivery.captureTarget(client: client)
        let pasteboard = testPasteboard()

        let result = TextDelivery.deliver("bound transcript", to: target, pasteboard: pasteboard, client: client)

        guard case .pasteCommandPosted = result else { return XCTFail("Expected paste delivery") }
        XCTAssertEqual(posted, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "bound transcript")
    }

    @MainActor
    func testChangedElementCopiesWithoutPostingPaste() {
        let original = AXUIElementCreateApplication(101)
        let changed = AXUIElementCreateApplication(102)
        let target = TextDelivery.captureTarget(client: accessibilityClient(
            focus: { self.focus(pid: 101, element: original) }
        ))
        var posted = false
        let deliveryClient = accessibilityClient(
            focus: { self.focus(pid: 101, element: changed) },
            post: { posted = true; return true }
        )
        let pasteboard = testPasteboard()

        let result = TextDelivery.deliver("private transcript", to: target,
            pasteboard: pasteboard, client: deliveryClient)

        guard case .copied = result else { return XCTFail("Expected clipboard fallback") }
        XCTAssertFalse(posted)
        XCTAssertEqual(pasteboard.string(forType: .string), "private transcript")
    }

    @MainActor
    func testChangedApplicationCopiesWithoutPostingPaste() {
        let element = AXUIElementCreateApplication(101)
        let target = TextDelivery.captureTarget(client: accessibilityClient(
            focus: { self.focus(pid: 101, element: element) }
        ))
        var posted = false
        let deliveryClient = accessibilityClient(
            focus: { self.focus(pid: 202, element: element) },
            post: { posted = true; return true }
        )

        let result = TextDelivery.deliver("private transcript", to: target,
            pasteboard: testPasteboard(), client: deliveryClient)

        guard case .copied = result else { return XCTFail("Expected clipboard fallback") }
        XCTAssertFalse(posted)
    }

    @MainActor
    func testTargetThatBecomesSecureCopiesWithoutPostingPaste() {
        let element = AXUIElementCreateApplication(101)
        let focus = focus(pid: 101, element: element)
        let target = TextDelivery.captureTarget(client: accessibilityClient(focus: { focus }))
        var posted = false
        let deliveryClient = accessibilityClient(focus: { focus }, eligible: { _ in false },
            post: { posted = true; return true })

        let result = TextDelivery.deliver("private transcript", to: target,
            pasteboard: testPasteboard(), client: deliveryClient)

        guard case .copied = result else { return XCTFail("Expected clipboard fallback") }
        XCTAssertFalse(posted)
    }

    @MainActor
    func testFinalFocusChangeCopiesWithoutPostingPaste() {
        let original = AXUIElementCreateApplication(101)
        let changed = AXUIElementCreateApplication(102)
        let target = TextDelivery.captureTarget(client: accessibilityClient(
            focus: { self.focus(pid: 101, element: original) }
        ))
        var focuses = [
            focus(pid: 101, element: original),
            focus(pid: 101, element: changed),
        ]
        var posted = false
        let deliveryClient = accessibilityClient(
            focus: { focuses.removeFirst() },
            post: { posted = true; return true }
        )

        let result = TextDelivery.deliver("private transcript", to: target,
            pasteboard: testPasteboard(), client: deliveryClient)

        guard case .copied = result else { return XCTFail("Expected clipboard fallback") }
        XCTAssertFalse(posted)
    }

    @MainActor
    func testReusedPIDFromDifferentApplicationInstanceCopiesWithoutPostingPaste() {
        let element = AXUIElementCreateApplication(101)
        let currentFocus = focus(pid: 101, element: element)
        let target = TextDelivery.captureTarget(client: accessibilityClient(focus: { currentFocus }))
        var posted = false
        let deliveryClient = accessibilityClient(
            focus: { currentFocus },
            applicationsMatch: { _, _ in false },
            post: { posted = true; return true }
        )

        let result = TextDelivery.deliver("private transcript", to: target,
            pasteboard: testPasteboard(), client: deliveryClient)

        guard case .copied = result else { return XCTFail("Expected clipboard fallback") }
        XCTAssertFalse(posted)
    }

    @MainActor
    func testMissingOrUntrustedTargetCopiesWithoutPostingPaste() {
        var posted = false
        let client = accessibilityClient(
            trusted: false,
            focus: { nil },
            post: { posted = true; return true }
        )
        XCTAssertNil(TextDelivery.captureTarget(client: client))

        let result = TextDelivery.deliver("private transcript", to: nil,
            pasteboard: testPasteboard(), client: client)

        guard case .copied = result else { return XCTFail("Expected clipboard fallback") }
        XCTAssertFalse(posted)
    }

    @MainActor
    func testSubroleValidationFailsClosed() {
        XCTAssertFalse(TextDelivery.nonSecureSubrole(error: .success, value: nil))
        XCTAssertFalse(TextDelivery.nonSecureSubrole(error: .success, value: NSNumber(value: 1)))
        XCTAssertFalse(TextDelivery.nonSecureSubrole(error: .success,
            value: kAXSecureTextFieldSubrole as CFString))
        XCTAssertTrue(TextDelivery.nonSecureSubrole(error: .success, value: "AXSearchField" as CFString))
        XCTAssertTrue(TextDelivery.nonSecureSubrole(error: .noValue, value: nil))
        XCTAssertTrue(TextDelivery.nonSecureSubrole(error: .attributeUnsupported, value: nil))
        XCTAssertFalse(TextDelivery.nonSecureSubrole(error: .cannotComplete, value: nil))
    }

    @MainActor
    private func accessibilityClient(
        trusted: Bool = true,
        focus: @escaping @MainActor () -> TextDelivery.Focus?,
        eligible: @escaping @MainActor (AXUIElement) -> Bool = { _ in true },
        applicationsMatch: @escaping @MainActor (NSRunningApplication, NSRunningApplication) -> Bool = { _, _ in true },
        post: @escaping @MainActor () -> Bool = { true }
    ) -> TextDelivery.AccessibilityClient {
        TextDelivery.AccessibilityClient(
            processID: 999,
            isTrusted: { trusted },
            currentFocus: focus,
            isEditableAndNonSecure: eligible,
            elementsEqual: { CFEqual($0, $1) },
            applicationsMatch: applicationsMatch,
            postPasteCommand: post
        )
    }

    @MainActor
    private func focus(pid: pid_t, element: AXUIElement) -> TextDelivery.Focus {
        TextDelivery.Focus(pid: pid, element: element, application: .current)
    }

    @MainActor
    private func testPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("pro.leets.sayall.tests.\(UUID().uuidString)"))
    }
}

final class HelperDecoderTests: XCTestCase {
    func testSuccessAndNoSpeechDecode() throws {
        XCTAssertEqual(try HelperDecoder.decode(Data(#"{"version":1,"status":"success","text":"hello"}"#.utf8)).text, "hello")
        XCTAssertEqual(try HelperDecoder.decode(Data(#"{"version":1,"status":"no_speech"}"#.utf8)).status, .noSpeech)
    }
    func testStableErrorMapping() {
        XCTAssertThrowsError(try HelperDecoder.decode(Data(#"{"version":1,"status":"error","error":"network"}"#.utf8))) { XCTAssertEqual($0 as? HelperFailure, .unsuccessful("network")) }
        XCTAssertThrowsError(try HelperDecoder.decode(Data("nope".utf8))) { XCTAssertEqual($0 as? HelperFailure, .malformedOutput) }
        XCTAssertThrowsError(try HelperDecoder.decode(Data(repeating: 0, count: HelperDecoder.maximumOutputBytes + 1))) { XCTAssertEqual($0 as? HelperFailure, .oversizedOutput) }
    }

    func testStreamingDecoderRequiresReadyAndTerminalFrames() throws {
        let output = Data("""
        {"version":1,"event":"ready","streaming":true}
        {"version":1,"status":"success","text":"hello"}

        """.utf8)
        XCTAssertEqual(try StreamingHelperDecoder.decode(output).text, "hello")
        XCTAssertThrowsError(try StreamingHelperDecoder.decode(Data("{}\n".utf8)))
    }
}

final class HelperRunnerTests: XCTestCase {
    func testClosesRequestPipeBeforeWaitingForResponse() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("helper.c")
        let executable = directory.appendingPathComponent("helper")
        try Data(#"""
#include <stdio.h>
extern char **environ;
int main(void) {
    if (environ[0] != NULL) return 4;
    while (getchar() != EOF) {}
    fputs("{\"version\":1,\"status\":\"success\",\"text\":\"ok\"}", stdout);
    return 0;
}
"""#.utf8).write(to: source)
        try runProcess("/usr/bin/clang", [source.path, "-o", executable.path])
        try runProcess("/usr/bin/codesign", ["--force", "--sign", "-", executable.path])
        let result = try await HelperRunner(executableURL: executable).run(
            batchRequest(),
            timeout: 2
        )
        XCTAssertEqual(result.text, "ok")
    }

    func testStreamingHelperWaitsForExplicitFinish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("helper.c")
        let executable = directory.appendingPathComponent("helper")
        try Data(#"""
#include <stdio.h>
#include <string.h>
extern char **environ;
int main(int argc, char **argv) {
    char line[65536];
    if (environ[0] != NULL) return 4;
    if (argc != 2 || strcmp(argv[1], "--stream") != 0 || !fgets(line, sizeof(line), stdin)) return 2;
    fputs("{\"version\":1,\"event\":\"ready\",\"streaming\":true}\n", stdout);
    fflush(stdout);
    if (!fgets(line, sizeof(line), stdin) || !strstr(line, "\"command\":\"finish\"")) return 3;
    fputs("{\"version\":1,\"status\":\"success\",\"text\":\"streamed\"}\n", stdout);
    return 0;
}
"""#.utf8).write(to: source)
        try runProcess("/usr/bin/clang", [source.path, "-o", executable.path])
        try runProcess("/usr/bin/codesign", ["--force", "--sign", "-", executable.path])
        let session = try await HelperRunner(executableURL: executable).launchStreaming(streamRequest())
        let result = try await session.finish(forceRest: false, timeout: 2)
        XCTAssertEqual(result.text, "streamed")
    }

    func testTerminalStreamingFailureIsNotEligibleForSecondHelper() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("helper.c")
        let executable = directory.appendingPathComponent("helper")
        try Data(#"""
#include <stdio.h>
int main(void) {
    char line[65536];
    if (!fgets(line, sizeof(line), stdin)) return 2;
    fputs("{\"version\":1,\"event\":\"ready\",\"streaming\":true}\n", stdout); fflush(stdout);
    if (!fgets(line, sizeof(line), stdin)) return 3;
    fputs("{\"version\":1,\"status\":\"error\",\"error\":\"deepgram_network\"}\n", stdout);
    return 0;
}
"""#.utf8).write(to: source)
        try runProcess("/usr/bin/clang", [source.path, "-o", executable.path])
        try runProcess("/usr/bin/codesign", ["--force", "--sign", "-", executable.path])
        let session = try await HelperRunner(executableURL: executable).launchStreaming(streamRequest())
        do {
            _ = try await session.finish(forceRest: false, timeout: 2)
            XCTFail("Expected the terminal provider failure")
        } catch let failure as HelperFailure {
            XCTAssertEqual(failure, .unsuccessful("deepgram_network"))
            XCTAssertFalse(Coordinator.shouldFallBackToBatch(after: failure))
        }
    }

    func testCancellationWaitsForForcedHelperExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("helper.c")
        let executable = directory.appendingPathComponent("helper")
        try Data(#"""
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
int main(void) {
    char line[65536];
    for (int number = 1; number < 32; number++) signal(number, SIG_IGN);
    if (!fgets(line, sizeof(line), stdin)) return 2;
    fputs("{\"version\":1,\"event\":\"ready\",\"streaming\":true}\n", stdout); fflush(stdout);
    for (;;) pause();
}
"""#.utf8).write(to: source)
        try runProcess("/usr/bin/clang", [source.path, "-o", executable.path])
        try runProcess("/usr/bin/codesign", ["--force", "--sign", "-", executable.path])
        let session = try await HelperRunner(executableURL: executable).launchStreaming(streamRequest())
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        await session.cancelAndWait()
        XCTAssertFalse(session.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testCancellingFinishEscalatesAndWaitsForHelperExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("helper.c")
        let executable = directory.appendingPathComponent("helper")
        try Data(#"""
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
int main(void) {
    char line[65536];
    for (int number = 1; number < 32; number++) signal(number, SIG_IGN);
    if (!fgets(line, sizeof(line), stdin)) return 2;
    fputs("{\"version\":1,\"event\":\"ready\",\"streaming\":true}\n", stdout); fflush(stdout);
    if (!fgets(line, sizeof(line), stdin)) return 3;
    for (;;) pause();
}
"""#.utf8).write(to: source)
        try runProcess("/usr/bin/clang", [source.path, "-o", executable.path])
        try runProcess("/usr/bin/codesign", ["--force", "--sign", "-", executable.path])
        let session = try await HelperRunner(executableURL: executable).launchStreaming(streamRequest())
        let finish = Task { try await session.finish(forceRest: false, timeout: 10) }
        try await Task.sleep(for: .milliseconds(100))
        finish.cancel()
        do { _ = try await finish.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        catch { XCTFail("Expected cancellation, got \(error)") }
        XCTAssertFalse(session.isRunning)
    }

    private func runProcess(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func batchRequest() -> HelperRequest {
        HelperRequest(version: 1, wavPath: "/tmp/audio.wav", deepgramAPIKey: "key",
            deepgramModel: "nova-3", deepgramLanguage: "en", deepgramRegion: "eu",
            deepgramKeyterms: ["SayAll"], groqAPIKey: "", groqModel: "llama-3.1-8b-instant",
            groqBaseURL: "https://api.groq.com/openai/v1/chat/completions", cleanupEnabled: false)
    }

    private func streamRequest() -> StreamingHelperRequest {
        StreamingHelperRequest(version: 1, wavPath: "/tmp/audio.wav", pcmPath: "/tmp/audio.pcm",
            deepgramAPIKey: "key", deepgramModel: "nova-3", deepgramLanguage: "en",
            deepgramRegion: "eu", deepgramKeyterms: ["SayAll"], streamFinalizeTimeoutMs: 2_000,
            groqAPIKey: "", groqModel: "llama-3.1-8b-instant",
            groqBaseURL: "https://api.groq.com/openai/v1/chat/completions", cleanupEnabled: false)
    }
}

final class ProcessingOwnershipTests: XCTestCase {
    func testOnlyPreFinishFailureCanTransferOwnershipToBatch() {
        XCTAssertTrue(Coordinator.shouldFallBackToBatch(after: .streamUnavailableBeforeFinish))
        XCTAssertFalse(Coordinator.shouldFallBackToBatch(after: .timeout))
        XCTAssertFalse(Coordinator.shouldFallBackToBatch(after: .malformedOutput))
        XCTAssertFalse(Coordinator.shouldFallBackToBatch(after: .unsuccessful("deepgram_network")))
    }

    func testFallbackUsesRemainingTimeFromOnePostStopDeadline() throws {
        let started = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(try Coordinator.remainingProcessingTime(since: started,
            now: started.addingTimeInterval(17)), 28, accuracy: 0.001)
        XCTAssertThrowsError(try Coordinator.remainingProcessingTime(since: started,
            now: started.addingTimeInterval(45))) { XCTAssertEqual($0 as? HelperFailure, .timeout) }
    }

    func testCaptureFailureCannotValidateAsSuccessfulRecording() {
        XCTAssertThrowsError(try AudioCapture.validateCapture(frames: 16_000, failed: true)) {
            XCTAssertTrue($0 is AudioCapture.CaptureError)
        }
    }
}

final class ConfigurationLoaderTests: XCTestCase {
    func testLoadsLinuxConfigSchema() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent(".config/sayall")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"stt":{"provider":"deepgram","api_key":"deepgram","model":"nova-3","language":"en-GB","region":"eu","streaming":false,"stream_finalize_timeout_ms":3500},"llm":{"provider":"groq","api_key":"groq","model":"llama-3.1-8b-instant","base_url":"https://api.groq.com/openai/v1/chat/completions","enabled":true},"output":{"method":"type"}}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        try Data(#"{"version":1,"keywords":["SayAll","München"]}"#.utf8)
            .write(to: directory.appendingPathComponent("keywords.json"))
        XCTAssertEqual(try ConfigurationLoader(environment: [:], homeDirectory: home).load(),
            ProviderSettings(deepgramAPIKey: "deepgram", deepgramModel: "nova-3", deepgramLanguage: "en-GB",
                deepgramRegion: "eu", deepgramKeyterms: ["SayAll", "München"], streamingEnabled: false,
                streamFinalizeTimeoutMs: 3_500, groqAPIKey: "groq", groqModel: "llama-3.1-8b-instant",
                groqBaseURL: "https://api.groq.com/openai/v1/chat/completions", cleanupEnabled: true))
    }

    func testEnvironmentOverridesAndReferences() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent("config/sayall")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"stt":{"api_key":"$FILE_DG"},"llm":{"api_key":"unused","enabled":false}}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        let environment = ["XDG_CONFIG_HOME": home.appendingPathComponent("config").path,
            "FILE_DG": "resolved", "GROQ_API_KEY": "override"]
        XCTAssertEqual(try ConfigurationLoader(environment: environment, homeDirectory: home).load(),
            ProviderSettings(deepgramAPIKey: "resolved", deepgramModel: "nova-3", deepgramLanguage: "en",
                deepgramRegion: "global", deepgramKeyterms: [], streamingEnabled: true,
                streamFinalizeTimeoutMs: 2_000, groqAPIKey: "override", groqModel: "llama-3.1-8b-instant",
                groqBaseURL: "https://api.groq.com/openai/v1/chat/completions", cleanupEnabled: false))
    }

    func testMissingAndMalformedConfiguration() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let loader = ConfigurationLoader(environment: [:], homeDirectory: home)
        XCTAssertThrowsError(try loader.load()) { XCTAssertEqual($0 as? ConfigurationError, .missingDeepgramKey) }
        try FileManager.default.createDirectory(at: loader.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: loader.url)
        XCTAssertThrowsError(try loader.load()) { XCTAssertEqual($0 as? ConfigurationError, .malformed) }

        try Data(#"{"stt":{"api_key":"key","region":"somewhere"}}"#.utf8).write(to: loader.url)
        XCTAssertThrowsError(try loader.load()) { XCTAssertEqual($0 as? ConfigurationError, .invalidProvider) }
    }

    func testEnvironmentOnlyConfigurationDoesNotRequireAFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try ConfigurationLoader(environment: ["DEEPGRAM_API_KEY": "shell-key"],
            homeDirectory: home).load()
        XCTAssertEqual(settings.deepgramAPIKey, "shell-key")
        XCTAssertTrue(settings.streamingEnabled)
    }
}

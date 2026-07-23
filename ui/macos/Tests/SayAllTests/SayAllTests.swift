import XCTest
import AppKit
@testable import SayAll

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
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("pro.saiem.sayall.tests.\(UUID().uuidString)"))
        let text = "SayAll delivery test 👋\nsecond line"

        XCTAssertTrue(TextDelivery.copy(text, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), text)
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

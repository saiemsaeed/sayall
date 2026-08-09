import XCTest
import AppKit
import ApplicationServices
import AVFoundation
import AudioToolbox
import Darwin
@testable import SayAll
import SayAllControl

final class ControlFoundationTests: XCTestCase {
    func testControlProtocolRoundTripsStableState() throws {
        let response = ControlResponse(ok: false, state: "processing", error: "busy: SayAll is processing")
        XCTAssertEqual(try JSONDecoder().decode(ControlResponse.self, from: JSONEncoder().encode(response)), response)
    }

    func testV2ControlCodecAcceptsAdditionsAndRejectsUnknownClosedState() throws {
        let additive = Data(#"{"version":2,"ok":true,"state":"idle","future":true}"#.utf8)
        let response = try JSONDecoder().decode(HostControlResponse.self, from: additive)
        try response.validate()
        XCTAssertEqual(response.state, .idle)
        XCTAssertThrowsError(try JSONDecoder().decode(HostControlResponse.self,
            from: Data(#"{"version":2,"ok":true,"state":"future"}"#.utf8)))
        let invalid = try JSONDecoder().decode(HostControlResponse.self,
            from: Data(#"{"version":2,"ok":false,"state":"idle"}"#.utf8))
        XCTAssertThrowsError(try invalid.validate())
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

    func testControlFrameInclusiveNewlineBoundaries() throws {
        func read(_ payloadBytes: Int) throws -> Data {
            var descriptors = [Int32](repeating: -1, count: 2)
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
            defer { close(descriptors[0]); close(descriptors[1]) }
            var frame = Data(repeating: 0x61, count: payloadBytes); frame.append(0x0a)
            let writer = descriptors[1]
            DispatchQueue.global().async {
                try? ControlSocket.writeAll(frame, to: writer, deadline: ControlSocket.deadline(afterMilliseconds: 1_000))
            }
            return try ControlSocket.readLine(from: descriptors[0], deadline: ControlSocket.deadline(afterMilliseconds: 1_000))
        }
        XCTAssertEqual(try read(ControlSocket.maximumFrameBytes - 1).count, ControlSocket.maximumFrameBytes - 1)
        XCTAssertThrowsError(try read(ControlSocket.maximumFrameBytes))

        XCTAssertLessThanOrEqual(try ControlSocket.encodeFrame(HostControlResponse(ok: false, state: .error,
            error: .init(code: "error", message: "failed"))).count, ControlSocket.maximumFrameBytes)
        XCTAssertThrowsError(try ControlSocket.encodeFrame(HostControlResponse(ok: false, state: .error,
            error: .init(code: "error", message: String(repeating: "x", count: ControlSocket.maximumFrameBytes)))))
    }

    func testV2FailureBoundaryRemovesOnlyExactLegacyPrefix() {
        XCTAssertEqual(hostV2Failure("busy: SayAll is processing", method: .toggle),
            HostControlError(code: "busy", message: "SayAll is processing"))
        XCTAssertEqual(hostV2Failure("error: Failed", method: .toggle),
            HostControlError(code: "unavailable", message: "Failed"))
        XCTAssertEqual(hostV2Failure("error: Invalid JSON", method: .reload),
            HostControlError(code: "invalid_config", message: "Invalid JSON"))
        XCTAssertEqual(hostV2Failure("busywork", method: .toggle),
            HostControlError(code: "busy", message: "busywork"))
    }

    @MainActor
    func testControlRouteDispatchesCompatibleEnvelopesExactlyOnce() throws {
        let v1 = try JSONEncoder().encode(ControlRequest(method: .status))
        let v2 = try JSONEncoder().encode(HostControlRequest(version: 2, method: .toggle))
        let reload = try JSONEncoder().encode(HostControlRequest(version: 2, method: .reload))
        XCTAssertEqual(decodeControlRoute(v1), .v1(.status))
        XCTAssertEqual(decodeControlRoute(v2), .v2(.toggle))
        XCTAssertEqual(decodeControlRoute(reload), .v2(.reload))

        var calls: [ControlMethod] = []
        _ = dispatchControlRoute(decodeControlRoute(v1)) { calls.append($0) }
        _ = dispatchControlRoute(decodeControlRoute(v2)) { calls.append($0) }
        _ = dispatchControlRoute(decodeControlRoute(reload)) { calls.append($0) }
        XCTAssertEqual(calls, [.status, .toggle, .reload])

        _ = dispatchControlRoute(decodeControlRoute(Data("{broken".utf8))) { calls.append($0) }
        _ = dispatchControlRoute(decodeControlRoute(Data("{\"version\":3,\"method\":\"toggle\"}".utf8))) { calls.append($0) }
        _ = dispatchControlRoute(decodeControlRoute(Data("{\"version\":2,\"method\":\"future\"}".utf8))) { calls.append($0) }
        XCTAssertEqual(calls, [.status, .toggle, .reload])
    }
}

final class CoordinatorControlTests: XCTestCase {
    @MainActor
    func testReloadValidatesConfigurationAndRejectsBusyState() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let loader = ConfigurationLoader(environment: ["DEEPGRAM_API_KEY": "key"], homeDirectory: home)
        var changes = 0
        let coordinator = Coordinator(configuration: loader) { changes += 1 }

        let valid = coordinator.handleControl(.reload)
        XCTAssertTrue(valid.ok)
        XCTAssertEqual(valid.state, "idle")
        XCTAssertEqual(changes, 1)

        try FileManager.default.createDirectory(at: loader.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: loader.url)
        let invalid = coordinator.handleControl(.reload)
        XCTAssertFalse(invalid.ok)
        XCTAssertTrue(invalid.error?.hasPrefix("error: ") == true)
        XCTAssertEqual(coordinator.state, .idle)

        try Data(#"{"stt":{"api_key":"key"},"output":{"method":"clipboard"},"metrics":{"enabled":false}}"#.utf8)
            .write(to: loader.url)
        XCTAssertTrue(coordinator.handleControl(.reload).ok)
        coordinator.trigger(source: .menu)
        let busy = coordinator.handleControl(.reload)
        XCTAssertFalse(busy.ok)
        XCTAssertTrue(busy.error?.hasPrefix("busy: ") == true)
        coordinator.cancel()
    }
}

final class StateMachineTests: XCTestCase {
    func testLegalRecordingPipeline() throws {
        var sut = StateMachine()
        for state in [DictationState.starting, .recording, .stopping, .processing, .delivering, .success, .idle] {
            try sut.transition(to: state)
        }
        XCTAssertEqual(sut.state, .idle)
    }
    func testIllegalTransitionsDoNotMutate() {
        var sut = StateMachine()
        XCTAssertThrowsError(try sut.transition(to: .processing))
        XCTAssertEqual(sut.state, .idle)
    }
    func testStartupCanFailBeforeCaptureStarts() throws {
        var sut = StateMachine()
        try sut.transition(to: .error)
        XCTAssertEqual(sut.state, .error)
    }
    func testSuccessfulDeliveryCanHideImmediately() throws {
        var sut = StateMachine()
        for state in [DictationState.starting, .recording, .stopping, .processing, .delivering, .idle] {
            try sut.transition(to: state)
        }
        XCTAssertEqual(sut.state, .idle)
    }
    func testNoSpeechCanHideImmediatelyFromProcessing() throws {
        var sut = StateMachine()
        for state in [DictationState.starting, .recording, .stopping, .processing, .idle] {
            try sut.transition(to: state)
        }
        XCTAssertEqual(sut.state, .idle)
    }

    func testStartingCanOnlyBecomeRecordingErrorOrCancelled() throws {
        for terminal in [DictationState.recording, .error, .cancelled] {
            var sut = StateMachine()
            try sut.transition(to: .starting)
            try sut.transition(to: terminal)
        }
        for invalid in [DictationState.idle, .stopping, .processing, .delivering, .success] {
            var sut = StateMachine()
            try sut.transition(to: .starting)
            XCTAssertThrowsError(try sut.transition(to: invalid))
            XCTAssertEqual(sut.state, .starting)
        }
    }
}

final class HUDRenderingTests: XCTestCase {
    @MainActor
    func testProductionVariantsRenderAtFigmaDimensions() throws {
        let variants: [(String, DictationState, Bool, String)] = [
            ("starting", .starting, true, "Starting recording…"),
            ("recording-timed", .recording, true, ""),
            ("recording-timeless", .recording, false, ""),
            ("processing", .processing, true, ""),
            ("copied", .success, true, "Copied to clipboard"),
            ("error", .error, true, "Deepgram is unavailable"),
        ]
        for (name, state, showTimer, message) in variants {
            let view = HUDView(frame: NSRect(x: 0, y: 0, width: 244, height: 48))
            view.update(state: state, message: message, audioLevel: 0.85, showTimer: showTimer)
            for _ in 0..<12 { view.tick() }
            guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return XCTFail("Could not create \(name) render")
            }
            view.cacheDisplay(in: view.bounds, to: representation)
            XCTAssertEqual(representation.size.width, 244)
            XCTAssertEqual(representation.size.height, 48)
            guard let png = representation.representation(using: .png, properties: [:]) else {
                return XCTFail("Could not encode \(name) render")
            }
            if let directory = ProcessInfo.processInfo.environment["SAYALL_HUD_SNAPSHOT_DIR"] {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: directory),
                    withIntermediateDirectories: true
                )
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
            }
        }
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
    func testClipboardModeCopiesWithoutAccessibilityOrInsertion() {
        var accessibilityCalls = 0
        let touched = { accessibilityCalls += 1 }
        let client = TextDelivery.AccessibilityClient(
            processID: 999,
            isTrusted: { touched(); return false },
            currentFocus: { touched(); return nil },
            currentTarget: { touched(); return nil },
            requestAccessibility: { _ in touched(); return false },
            elementCapability: { _ in touched(); return .none },
            isSecureInputEnabled: { touched(); return false },
            elementsEqual: { _, _ in touched(); return false },
            applicationsMatch: { _, _ in touched(); return false },
            postPasteCommand: { _ in touched(); return false }
        )
        let pasteboard = testPasteboard()

        let result = TextDelivery.deliver("clipboard transcript", method: .clipboard, to: nil,
            pasteboard: pasteboard, client: client)

        guard case .copied = result else { return XCTFail("Expected explicit clipboard delivery") }
        XCTAssertEqual(pasteboard.string(forType: .string), "clipboard transcript")
        XCTAssertEqual(accessibilityCalls, 0)
    }

    @MainActor
    func testTypeModeCopiesAndPostsVerifiedPaste() {
        let element = AXUIElementCreateApplication(101)
        let focus = focus(pid: 101, element: element)
        var posted = false
        var postedPID: pid_t?
        let client = accessibilityClient(focus: { focus }, post: {
            postedPID = $0
            posted = true
            return true
        })
        let target = TextDelivery.captureTarget(client: client)
        let pasteboard = testPasteboard()
        XCTAssertTrue(TextDelivery.copy("existing clipboard", to: pasteboard))

        let result = TextDelivery.deliver("typed transcript", method: .type, to: target,
            pasteboard: pasteboard, client: client)

        guard case .typeCommandPosted = result else { return XCTFail("Expected type delivery") }
        XCTAssertTrue(posted)
        XCTAssertEqual(postedPID, 101)
        XCTAssertEqual(pasteboard.string(forType: .string), "typed transcript")
    }

    @MainActor
    func testTypeFailureFallsBackToClipboard() {
        let element = AXUIElementCreateApplication(101)
        let focus = focus(pid: 101, element: element)
        let client = accessibilityClient(focus: { focus }, post: { _ in false })
        let target = TextDelivery.captureTarget(client: client)
        let pasteboard = testPasteboard()

        let result = TextDelivery.deliver("recoverable transcript", method: .type, to: target,
            pasteboard: pasteboard, client: client)

        guard case .copiedFallback = result else { return XCTFail("Expected clipboard fallback") }
        XCTAssertEqual(pasteboard.string(forType: .string), "recoverable transcript")
    }

    @MainActor
    func testPasteOnlyTextAreaUsesVerifiedPasteForTypeMode() {
        let element = AXUIElementCreateApplication(101)
        let focus = focus(pid: 101, element: element)
        var posted = false
        let client = accessibilityClient(focus: { focus }, eligible: { _ in false },
            pasteOnlySurface: { _ in true }, post: { _ in posted = true; return true })
        let target = TextDelivery.captureTarget(client: client)
        let pasteboard = testPasteboard()

        let result = TextDelivery.deliver("terminal transcript", method: .type, to: target,
            pasteboard: pasteboard, client: client)

        guard case .typeCommandPosted = result else { return XCTFail("Expected text-area paste delivery") }
        XCTAssertTrue(posted)
        XCTAssertEqual(pasteboard.string(forType: .string), "terminal transcript")
    }

    @MainActor
    func testApplicationRootIsRejectedAsPasteOnlySurface() {
        let element = AXUIElementCreateApplication(101)
        let focus = focus(pid: 101, element: element)
        let client = accessibilityClient(focus: { focus }, eligible: { _ in false },
            pasteOnlySurface: { _ in false })

        XCTAssertNil(TextDelivery.captureTarget(client: client))
    }

    @MainActor
    func testSecureInputRejectsApplicationSurface() {
        let element = AXUIElementCreateApplication(101)
        let focus = focus(pid: 101, element: element)
        let client = accessibilityClient(focus: { focus }, eligible: { _ in false },
            pasteOnlySurface: { _ in true }, secureInput: { true })

        XCTAssertNil(TextDelivery.captureTarget(client: client))
    }

    @MainActor
    func testSecureInputActivatedDuringCaptureRejectsTarget() {
        let element = AXUIElementCreateApplication(101)
        let focus = focus(pid: 101, element: element)
        var secureStates = [false, true]
        let client = accessibilityClient(
            focus: { focus },
            secureInput: { secureStates.removeFirst() }
        )

        XCTAssertNil(TextDelivery.captureTarget(client: client))
    }

    @MainActor
    func testUnchangedEditableTargetPostsPasteAfterCopying() {
        let element = AXUIElementCreateApplication(101)
        let focus = focus(pid: 101, element: element)
        var posted = 0
        let client = accessibilityClient(focus: { focus }, post: { _ in posted += 1; return true })
        let target = TextDelivery.captureTarget(client: client)
        let pasteboard = testPasteboard()

        let result = TextDelivery.deliver("bound transcript", method: .paste, to: target,
            pasteboard: pasteboard, client: client)

        guard case .pasteCommandPosted = result else { return XCTFail("Expected paste delivery") }
        XCTAssertEqual(posted, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "bound transcript")
    }

    @MainActor
    func testRecreatedElementInSameWindowPostsPaste() {
        let window = AXUIElementCreateApplication(100)
        let original = AXUIElementCreateApplication(101)
        let recreated = AXUIElementCreateApplication(102)
        let target = TextDelivery.captureTarget(client: accessibilityClient(
            focus: { self.focus(pid: 101, element: original, window: window) }
        ))
        var posted = false
        let deliveryClient = accessibilityClient(
            focus: { self.focus(pid: 101, element: recreated, window: window) },
            post: { _ in posted = true; return true }
        )
        let pasteboard = testPasteboard()

        let result = TextDelivery.deliver("private transcript", method: .paste, to: target,
            pasteboard: pasteboard, client: deliveryClient)

        guard case .pasteCommandPosted = result else { return XCTFail("Expected paste delivery") }
        XCTAssertTrue(posted)
        XCTAssertEqual(pasteboard.string(forType: .string), "private transcript")
    }

    @MainActor
    func testChangedWindowCopiesWithoutPostingPaste() {
        let originalWindow = AXUIElementCreateApplication(100)
        let changedWindow = AXUIElementCreateApplication(200)
        let element = AXUIElementCreateApplication(101)
        let target = TextDelivery.captureTarget(client: accessibilityClient(
            focus: { self.focus(pid: 101, element: element, window: originalWindow) }
        ))
        var posted = false
        let deliveryClient = accessibilityClient(
            focus: { self.focus(pid: 101, element: element, window: changedWindow) },
            post: { _ in posted = true; return true }
        )

        let result = TextDelivery.deliver("private transcript", method: .paste, to: target,
            pasteboard: testPasteboard(), client: deliveryClient)

        guard case .copiedFallback = result else { return XCTFail("Expected clipboard fallback") }
        XCTAssertFalse(posted)
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
            post: { _ in posted = true; return true }
        )

        let result = TextDelivery.deliver("private transcript", method: .paste, to: target,
            pasteboard: testPasteboard(), client: deliveryClient)

        guard case .copiedFallback = result else { return XCTFail("Expected clipboard fallback") }
        XCTAssertFalse(posted)
    }

    @MainActor
    func testTargetThatBecomesSecureCopiesWithoutPostingPaste() {
        let element = AXUIElementCreateApplication(101)
        let focus = focus(pid: 101, element: element)
        let target = TextDelivery.captureTarget(client: accessibilityClient(focus: { focus }))
        var posted = false
        let deliveryClient = accessibilityClient(focus: { focus }, eligible: { _ in false },
            post: { _ in posted = true; return true })

        let result = TextDelivery.deliver("private transcript", method: .paste, to: target,
            pasteboard: testPasteboard(), client: deliveryClient)

        guard case .copiedFallback = result else { return XCTFail("Expected clipboard fallback") }
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
            post: { _ in posted = true; return true }
        )

        let result = TextDelivery.deliver("private transcript", method: .paste, to: target,
            pasteboard: testPasteboard(), client: deliveryClient)

        guard case .copiedFallback = result else { return XCTFail("Expected clipboard fallback") }
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
            post: { _ in posted = true; return true }
        )

        let result = TextDelivery.deliver("private transcript", method: .paste, to: target,
            pasteboard: testPasteboard(), client: deliveryClient)

        guard case .copiedFallback = result else { return XCTFail("Expected clipboard fallback") }
        XCTAssertFalse(posted)
    }

    @MainActor
    func testMissingOrUntrustedTargetCopiesWithoutPostingPaste() {
        var posted = false
        let client = accessibilityClient(
            trusted: false,
            focus: { nil },
            post: { _ in posted = true; return true }
        )
        XCTAssertNil(TextDelivery.captureTarget(client: client))

        let result = TextDelivery.deliver("private transcript", method: .paste, to: nil,
            pasteboard: testPasteboard(), client: client)

        guard case .copiedFallback = result else { return XCTFail("Expected clipboard fallback") }
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
    func testCapabilityClassificationAcceptsWritableCustomTextSurface() {
        XCTAssertEqual(TextDelivery.classify(.init(
            role: "AXCustomEditor", enabled: true, nonSecureSubrole: true,
            valueSettable: false, writableSelectionRange: true
        )), .editable)
        XCTAssertEqual(TextDelivery.classify(.init(
            role: kAXTextAreaRole as String, enabled: true, nonSecureSubrole: true,
            valueSettable: false, writableSelectionRange: false
        )), .pasteOnlyTextArea)
    }

    @MainActor
    func testCapabilityClassificationRejectsUnsafeOrNonTextValues() {
        XCTAssertEqual(TextDelivery.classify(.init(
            role: kAXSliderRole as String, enabled: true, nonSecureSubrole: true,
            valueSettable: true, writableSelectionRange: false
        )), .none)
        XCTAssertEqual(TextDelivery.classify(.init(
            role: kAXTextFieldRole as String, enabled: true, nonSecureSubrole: false,
            valueSettable: true, writableSelectionRange: true
        )), .none)
        XCTAssertEqual(TextDelivery.classify(.init(
            role: kAXTextFieldRole as String, enabled: false, nonSecureSubrole: true,
            valueSettable: true, writableSelectionRange: true
        )), .none)
    }

    @MainActor
    func testUnavailableFocusRequestsAccessibilityForCapturedWindow() {
        let element = AXUIElementCreateApplication(101)
        let initialFocus = focus(pid: 101, element: element)
        let initialTarget = TextDelivery.captureTarget(client: accessibilityClient(focus: { initialFocus }))
        var requested = false
        let hiddenTreeClient = accessibilityClient(
            focus: { nil },
            currentTarget: { initialTarget },
            requestAccessibility: { _ in requested = true; return true }
        )

        XCTAssertNotNil(TextDelivery.captureTarget(client: hiddenTreeClient))
        XCTAssertTrue(requested)
    }

    @MainActor
    private func accessibilityClient(
        trusted: Bool = true,
        focus: @escaping @MainActor () -> TextDelivery.Focus?,
        currentTarget: @escaping @MainActor () -> TextDelivery.Target? = { nil },
        requestAccessibility: @escaping @MainActor (TextDelivery.Target) -> Bool = { _ in false },
        eligible: @escaping @MainActor (AXUIElement) -> Bool = { _ in true },
        pasteOnlySurface: @escaping @MainActor (AXUIElement) -> Bool = { _ in false },
        secureInput: @escaping @MainActor () -> Bool = { false },
        applicationsMatch: @escaping @MainActor (NSRunningApplication, NSRunningApplication) -> Bool = { _, _ in true },
        post: @escaping @MainActor (pid_t) -> Bool = { _ in true }
    ) -> TextDelivery.AccessibilityClient {
        TextDelivery.AccessibilityClient(
            processID: 999,
            isTrusted: { trusted },
            currentFocus: focus,
            currentTarget: currentTarget,
            requestAccessibility: requestAccessibility,
            elementCapability: {
                if eligible($0) { return .editable }
                return pasteOnlySurface($0) ? .pasteOnlyTextArea : .none
            },
            isSecureInputEnabled: secureInput,
            elementsEqual: { CFEqual($0, $1) },
            applicationsMatch: applicationsMatch,
            postPasteCommand: post
        )
    }

    @MainActor
    private func focus(pid: pid_t, element: AXUIElement, window: AXUIElement? = nil) -> TextDelivery.Focus {
        TextDelivery.Focus(pid: pid, element: element, window: window ?? element, application: .current)
    }

    @MainActor
    private func testPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("pro.leets.sayall.tests.\(UUID().uuidString)"))
    }
}

final class AudioCaptureConversionTests: XCTestCase {
    func testActiveChannelMonoBufferPreservesTheLoudestInputChannel() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        )
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        input.frameLength = 8
        let channels = try XCTUnwrap(input.floatChannelData)
        for index in 0..<8 {
            channels[0][index] = 0.01
            channels[1][index] = -0.02
            channels[2][index] = Float(index + 1) / 10
            channels[3][index] = 0
        }

        let mono = try XCTUnwrap(AudioCapture.activeChannelMonoBuffer(from: input))

        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.frameLength, 8)
        let samples = try XCTUnwrap(mono.floatChannelData?[0])
        for index in 0..<8 {
            XCTAssertEqual(samples[index], channels[2][index])
        }
    }

    func testActiveChannelMonoBufferSupportsInt16Capture() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        )
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        input.frameLength = 8
        let channels = try XCTUnwrap(input.int16ChannelData)
        for index in 0..<8 {
            channels[0][index] = 100
            channels[1][index] = -200
            channels[2][index] = Int16((index + 1) * 1_000)
            channels[3][index] = 0
        }

        let mono = try XCTUnwrap(AudioCapture.activeChannelMonoBuffer(from: input))

        XCTAssertEqual(mono.format.commonFormat, .pcmFormatInt16)
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.frameLength, 8)
        let samples = try XCTUnwrap(mono.int16ChannelData?[0])
        for index in 0..<8 {
            XCTAssertEqual(samples[index], channels[2][index])
        }
    }

    func testActiveChannelMonoBufferSupportsInterleavedFloatCapture() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Quadraphonic))
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: true,
            channelLayout: layout
        )
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        input.frameLength = 8
        let source = try XCTUnwrap(
            UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList).first?.mData?
                .assumingMemoryBound(to: Float.self)
        )
        for frame in 0..<8 {
            source[frame * 4] = 0.01
            source[frame * 4 + 1] = -0.02
            source[frame * 4 + 2] = Float(frame + 1) / 10
            source[frame * 4 + 3] = 0
        }

        let mono = try XCTUnwrap(AudioCapture.activeChannelMonoBuffer(from: input))

        XCTAssertFalse(mono.format.isInterleaved)
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.frameLength, 8)
        let samples = try XCTUnwrap(mono.floatChannelData?[0])
        for frame in 0..<8 {
            XCTAssertEqual(samples[frame], source[frame * 4 + 2])
        }
    }

    func testResamplerKeepsStateAcrossChunksAndRebuildsForFormatChanges() throws {
        let resampler = AudioCapture.AudioResampler()
        let firstFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        var firstFrames = 0
        for chunk in 0..<20 {
            firstFrames += Int(try XCTUnwrap(resampler.convert(
                inputBuffer(format: firstFormat, frames: 480, phase: chunk * 480)
            )).frameLength)
        }
        XCTAssertEqual(resampler.converterGeneration, 1)
        XCTAssertLessThanOrEqual(abs(firstFrames - 3_200), 64)

        let secondFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ))
        var secondFrames = 0
        for chunk in 0..<20 {
            secondFrames += Int(try XCTUnwrap(resampler.convert(
                inputBuffer(format: secondFormat, frames: 240, phase: chunk * 240)
            )).frameLength)
        }
        XCTAssertEqual(resampler.converterGeneration, 2)
        XCTAssertLessThanOrEqual(abs(secondFrames - 3_200), 64)
    }

    private func inputBuffer(format: AVAudioFormat, frames: AVAudioFrameCount, phase: Int) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = sin(Float(phase + index) * 0.05) * 0.25
        }
        return buffer
    }
}

final class HelperDecoderTests: XCTestCase {
    func testSuccessAndNoSpeechDecode() throws {
        XCTAssertEqual(try HelperDecoder.decode(Data(#"{"version":2,"status":"success","text":"hello"}"#.utf8)).text, "hello")
        XCTAssertEqual(try HelperDecoder.decode(Data(#"{"version":2,"status":"no_speech"}"#.utf8)).status, .noSpeech)
    }
    func testStableErrorMapping() {
        XCTAssertThrowsError(try HelperDecoder.decode(Data(#"{"version":2,"status":"error","error":"network"}"#.utf8))) { XCTAssertEqual($0 as? HelperFailure, .unsuccessful("network")) }
        XCTAssertThrowsError(try HelperDecoder.decode(Data("nope".utf8))) { XCTAssertEqual($0 as? HelperFailure, .malformedOutput) }
        XCTAssertThrowsError(try HelperDecoder.decode(Data(repeating: 0, count: HelperDecoder.maximumOutputBytes + 1))) { XCTAssertEqual($0 as? HelperFailure, .oversizedOutput) }
    }

    func testStreamingDecoderRequiresReadyAndTerminalFrames() throws {
        let ready = try StreamingHelperDecoder.decodeReady(Data(#"{"version":2,"event":"ready","streaming":true}"#.utf8))
        XCTAssertTrue(ready.streaming)
        let rest = try StreamingHelperDecoder.decodeReady(Data(#"{"version":2,"event":"ready","streaming":false}"#.utf8))
        XCTAssertFalse(rest.streaming)
        XCTAssertEqual(try StreamingHelperDecoder.decode(Data(#"{"version":2,"status":"success","text":"hello"}"#.utf8)).text, "hello")
        XCTAssertThrowsError(try StreamingHelperDecoder.decodeReady(Data("{}".utf8)))
        XCTAssertThrowsError(try StreamingHelperDecoder.decodeReady(Data(#"{"version":1,"event":"ready","streaming":true}"#.utf8)))
        XCTAssertThrowsError(try StreamingHelperDecoder.decodeReady(Data(repeating: 0, count: StreamingHelperDecoder.maximumReadyBytes + 1)))
    }
}

final class HelperRunnerTests: XCTestCase {
    private actor ProbeCount {
        private(set) var value = 0

        func increment() { value += 1 }
    }

    func testCompatibilityRegistrySharesConcurrentProbe() async throws {
        let registry = CompatibilityRegistry()
        let probeCount = ProbeCount()
        let expected = HelperRunner.CompatibilityToken(
            buildVersion: "test-build", codeIdentity: Data([0x01, 0x02]))

        async let first = registry.token(for: "helper\u{0}test-build") {
            await probeCount.increment()
            try await Task.sleep(for: .milliseconds(100))
            return expected
        }
        async let second = registry.token(for: "helper\u{0}test-build") {
            await probeCount.increment()
            try await Task.sleep(for: .milliseconds(100))
            return expected
        }

        let results = try await [first, second]
        let completedProbeCount = await probeCount.value
        XCTAssertEqual(results.map(\.buildVersion), ["test-build", "test-build"])
        XCTAssertEqual(results.map(\.codeIdentity), [Data([0x01, 0x02]), Data([0x01, 0x02])])
        XCTAssertEqual(completedProbeCount, 1)
    }

    func testCompatibilityProbeUsesOneDeadlineAcrossDelayedFrameAndExit() async throws {
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
    signal(SIGTERM, SIG_IGN);
    usleep(700000);
    fputs("{\"protocol_version\":2,\"build_version\":\"test-build\"}\n", stdout);
    fflush(stdout);
    sleep(3);
    return 0;
}
"""#.utf8).write(to: source)
        try runProcess("/usr/bin/clang", [source.path, "-o", executable.path])
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()

        let started = DispatchTime.now().uptimeNanoseconds
        do {
            try await HelperRunner.completeCompatibilityProbe(process: process, stdin: stdin, stdout: stdout,
                buildVersion: "test-build", timeout: 1)
            XCTFail("Expected the shared probe deadline to expire")
        } catch let failure as HelperFailure {
            XCTAssertEqual(failure, .timeout)
        }
        let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        // The one-second probe budget is followed only by requestTermination's
        // documented one-second TERM-to-SIGKILL escalation allowance.
        XCTAssertLessThan(elapsed, 2.5)
        XCTAssertGreaterThan(elapsed, 0.9)
        XCTAssertFalse(process.isRunning)
    }

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
    fputs("{\"version\":2,\"status\":\"success\",\"text\":\"ok\"}", stdout);
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
    fputs("{\"version\":2,\"event\":\"ready\",\"streaming\":true}\n", stdout);
    fflush(stdout);
    if (!fgets(line, sizeof(line), stdin) || !strstr(line, "\"command\":\"finish\"")) return 3;
    fputs("{\"version\":2,\"status\":\"success\",\"text\":\"streamed\"}\n", stdout);
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
    fputs("{\"version\":2,\"event\":\"ready\",\"streaming\":true}\n", stdout); fflush(stdout);
    if (!fgets(line, sizeof(line), stdin)) return 3;
    fputs("{\"version\":2,\"status\":\"error\",\"error\":\"deepgram_network\"}\n", stdout);
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
    fputs("{\"version\":2,\"event\":\"ready\",\"streaming\":true}\n", stdout); fflush(stdout);
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

    func testCancellingLaunchWhileReadyIsWithheldEscalatesAndSettles() async throws {
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
    for (;;) pause();
}
"""#.utf8).write(to: source)
        try runProcess("/usr/bin/clang", [source.path, "-o", executable.path])
        try runProcess("/usr/bin/codesign", ["--force", "--sign", "-", executable.path])
        let launch = Task {
            try await HelperRunner(executableURL: executable).launchStreaming(streamRequest())
        }
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        launch.cancel()
        do { _ = try await launch.value; XCTFail("Expected cancelled launch to fail") }
        catch {}
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
    fputs("{\"version\":2,\"event\":\"ready\",\"streaming\":true}\n", stdout); fflush(stdout);
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
        HelperRequest(version: ProcessingProtocol.version, wavPath: "/tmp/audio.wav", deepgramAPIKey: "key",
            deepgramModel: "nova-3", deepgramLanguage: "en", deepgramRegion: "eu",
            deepgramKeyterms: ["SayAll"], smartFormat: false, punctuate: false,
            dictation: false, numerals: false, measurements: false,
            groqAPIKey: "", groqModel: "llama-3.1-8b-instant",
            groqBaseURL: "https://api.groq.com/openai/v1/chat/completions", cleanupEnabled: false)
    }

    private func streamRequest() -> StreamingHelperRequest {
        StreamingHelperRequest(version: ProcessingProtocol.version, wavPath: "/tmp/audio.wav", pcmPath: "/tmp/audio.pcm",
            deepgramAPIKey: "key", deepgramModel: "nova-3", deepgramLanguage: "en",
            deepgramRegion: "eu", deepgramKeyterms: ["SayAll"],
            smartFormat: false, punctuate: false, dictation: false, numerals: false, measurements: false,
            streamFinalizeTimeoutMs: 2_000,
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

final class SharedBackendContractTests: XCTestCase {
    private struct WorkerReady: Decodable {
        let version: Int
        let event: String
        let streaming: Bool
    }

    private func fixture(_ name: String) throws -> Data {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try Data(contentsOf: root.appendingPathComponent("tests/contracts-0.2/\(name).json"))
    }

    func testWorkerFixturesMatchTheSwiftDecoder() throws {
        let info = try JSONDecoder().decode(WorkerInfo.self, from: fixture("worker-info"))
        XCTAssertEqual(info, WorkerInfo(protocolVersion: ProcessingProtocol.version, buildVersion: "0.1.8"))
        let ready = try JSONDecoder().decode(WorkerReady.self, from: fixture("worker-ready-streaming"))
        XCTAssertEqual(ready.version, ProcessingProtocol.version)
        XCTAssertEqual(ready.event, "ready")
        XCTAssertTrue(ready.streaming)
        XCTAssertFalse(try JSONDecoder().decode(WorkerReady.self, from: fixture("worker-ready-rest")).streaming)
        XCTAssertEqual(try JSONDecoder().decode(StreamingHelperFinish.self, from: fixture("worker-finish")),
            StreamingHelperFinish(version: ProcessingProtocol.version, command: "finish", forceRest: false))

        let success = try HelperDecoder.decode(fixture("worker-result-success"))
        XCTAssertEqual(success.status, .success)
        XCTAssertEqual(success.text, "Hello, world.")

        let warning = try HelperDecoder.decode(fixture("worker-result-cleanup-warning"))
        XCTAssertEqual(warning.warning, "cleanup_failed")
        XCTAssertEqual(warning.text, "raw transcript")

        XCTAssertEqual(try HelperDecoder.decode(fixture("worker-result-no-speech")).status, .noSpeech)
        XCTAssertThrowsError(try HelperDecoder.decode(fixture("worker-result-error"))) {
            XCTAssertEqual($0 as? HelperFailure, .unsuccessful("deepgram_rate_limited"))
        }
    }

    func testFutureUnifiedHostFixturesAreLanguageNeutral() throws {
        let decoder = JSONDecoder()
        let status = try decoder.decode(HostControlRequest.self, from: fixture("host-status-request"))
        XCTAssertEqual(status.version, 2)
        XCTAssertEqual(status.method, .status)
        XCTAssertEqual(try decoder.decode(HostControlRequest.self, from: fixture("host-toggle-request")).method, .toggle)
        XCTAssertEqual(try decoder.decode(HostControlRequest.self, from: fixture("host-reload-request")).method, .reload)

        let idle = try decoder.decode(HostControlResponse.self, from: fixture("host-status-response"))
        XCTAssertTrue(idle.ok)
        XCTAssertEqual(idle.state, .idle)
        XCTAssertNil(idle.error)

        let busy = try decoder.decode(HostControlResponse.self, from: fixture("host-busy-response"))
        XCTAssertFalse(busy.ok)
        XCTAssertEqual(busy.state, .processing)
        XCTAssertEqual(busy.error?.code, "busy")
        XCTAssertEqual(busy.error?.message, "SayAll is processing")
    }
}

final class ConfigurationLoaderTests: XCTestCase {
    func testLoadsLinuxConfigSchema() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent(".config/sayall")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"stt":{"provider":"deepgram","api_key":"deepgram","model":"nova-3","language":"en-GB","region":"eu","smart_format":true,"punctuate":true,"dictation":true,"numerals":true,"measurements":true,"streaming":false,"stream_finalize_timeout_ms":3500},"llm":{"provider":"groq","api_key":"groq","model":"llama-3.1-8b-instant","base_url":"https://api.groq.com/openai/v1/chat/completions","enabled":true},"output":{"method":"paste","trailing_space":false},"metrics":{"enabled":false,"history_max_entries":12},"hud":{"show_timer":false}}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        try Data(#"{"version":1,"keywords":["SayAll","München"]}"#.utf8)
            .write(to: directory.appendingPathComponent("keywords.json"))
        XCTAssertEqual(try ConfigurationLoader(environment: [:], homeDirectory: home).load(),
            ProviderSettings(deepgramAPIKey: "deepgram", deepgramModel: "nova-3", deepgramLanguage: "en-GB",
                deepgramRegion: "eu", deepgramKeyterms: ["SayAll", "München"],
                smartFormat: true, punctuate: true, dictation: true, numerals: true, measurements: true,
                streamingEnabled: false,
                streamFinalizeTimeoutMs: 3_500, groqAPIKey: "groq", groqModel: "llama-3.1-8b-instant",
                groqBaseURL: "https://api.groq.com/openai/v1/chat/completions", cleanupEnabled: true,
                showTimer: false, outputMethod: .paste, trailingSpace: false,
                metricsEnabled: false, metricsHistoryMaxEntries: 12))
    }

    func testEnvironmentOverridesAndReferences() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent("config/sayall")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"stt":{"api_key":"$FILE_DG"},"llm":{"api_key":"unused"}}"#.utf8)
            .write(to: directory.appendingPathComponent("config.json"))
        let environment = ["XDG_CONFIG_HOME": home.appendingPathComponent("config").path,
            "FILE_DG": "resolved", "GROQ_API_KEY": "override"]
        XCTAssertEqual(try ConfigurationLoader(environment: environment, homeDirectory: home).load(),
            ProviderSettings(deepgramAPIKey: "resolved", deepgramModel: "nova-3", deepgramLanguage: "en",
                deepgramRegion: "global", deepgramKeyterms: [],
                smartFormat: false, punctuate: false, dictation: false, numerals: false, measurements: false,
                streamingEnabled: true,
                streamFinalizeTimeoutMs: 2_000, groqAPIKey: "override", groqModel: "openai/gpt-oss-20b",
                groqBaseURL: "https://api.groq.com/openai/v1/chat/completions", cleanupEnabled: false,
                showTimer: true, outputMethod: .type, trailingSpace: true,
                metricsEnabled: true, metricsHistoryMaxEntries: 1_000))
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

        try Data(#"{"stt":{"api_key":"key"},"output":{"method":"unknown"}}"#.utf8).write(to: loader.url)
        XCTAssertThrowsError(try loader.load()) { XCTAssertEqual($0 as? ConfigurationError, .invalidOutputMethod) }

        try Data(#"{"stt":{"api_key":"key"},"metrics":{"history_max_entries":100001}}"#.utf8).write(to: loader.url)
        XCTAssertThrowsError(try loader.load()) { XCTAssertEqual($0 as? ConfigurationError, .invalidMetrics) }
    }

    func testLLMModelAcceptsOneOptionalNamespace() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let loader = ConfigurationLoader(environment: [:], homeDirectory: home)
        try FileManager.default.createDirectory(at: loader.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"stt":{"api_key":"key"},"llm":{"model":"openai/gpt-oss-20b"}}"#.utf8).write(to: loader.url)
        XCTAssertEqual(try loader.load().groqModel, "openai/gpt-oss-20b")
        for model in ["/openai", "openai/", "a/b/c", String(repeating: "a", count: 65)] {
            let json = #"{"stt":{"api_key":"key"},"llm":{"model":"\#(model)"}}"#
            try Data(json.utf8).write(to: loader.url)
            XCTAssertThrowsError(try loader.load()) { XCTAssertEqual($0 as? ConfigurationError, .invalidProvider) }
        }
    }

    func testEnvironmentOnlyConfigurationDoesNotRequireAFile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = try ConfigurationLoader(environment: ["DEEPGRAM_API_KEY": "shell-key"],
            homeDirectory: home).load()
        XCTAssertEqual(settings.deepgramAPIKey, "shell-key")
        XCTAssertTrue(settings.streamingEnabled)
        XCTAssertEqual(settings.outputMethod, .type)
        XCTAssertTrue(settings.trailingSpace)
        XCTAssertTrue(settings.metricsEnabled)
        XCTAssertEqual(settings.metricsHistoryMaxEntries, 1_000)
    }
}

final class StartupMetricsTests: XCTestCase {
    func testStorePersistsBoundedPrivacySafeSamples() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("startup-metrics-v1.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StartupMetricsStore(url: url)
        let first = StartupMetricSample(shortcutToHUDMs: 12, shortcutToRecordingReadyMs: 320,
            targetCaptureMs: 4, configLoadMs: 2, microphonePermissionMs: 0,
            compatibilityMs: 100, audioStartMs: 80, streamReadyMs: 134,
            outcome: "recording_ready")
        let second = StartupMetricSample(shortcutToHUDMs: 9, shortcutToRecordingReadyMs: nil,
            targetCaptureMs: 3, configLoadMs: 1, microphonePermissionMs: 0,
            compatibilityMs: 0, audioStartMs: 0, streamReadyMs: 0,
            outcome: "cancelled")

        await store.record(first, enabled: true, limit: 1)
        await store.record(second, enabled: true, limit: 1)

        let samples = await store.samplesForTesting()
        XCTAssertEqual(samples, [second])
        let encoded = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(encoded.contains("transcript"))
        XCTAssertFalse(encoded.contains("application"))
        XCTAssertFalse(encoded.contains("api_key"))
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directoryMode = try XCTUnwrap(directoryAttributes[.posixPermissions] as? NSNumber)
        let fileMode = try XCTUnwrap(fileAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(directoryMode.intValue & 0o777, 0o700)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
    }

    func testDisabledStoreWritesNothing() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("startup-metrics-v1.json")
        let store = StartupMetricsStore(url: url)
        let sample = StartupMetricSample(shortcutToHUDMs: 1, shortcutToRecordingReadyMs: 2,
            targetCaptureMs: 0, configLoadMs: 0, microphonePermissionMs: 0,
            compatibilityMs: 0, audioStartMs: 0, streamReadyMs: 0,
            outcome: "recording_ready")

        await store.record(sample, enabled: false, limit: 1_000)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testZeroRetentionRemovesExistingSamples() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("startup-metrics-v1.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StartupMetricsStore(url: url)
        let sample = StartupMetricSample(shortcutToHUDMs: 1, shortcutToRecordingReadyMs: 2,
            targetCaptureMs: 0, configLoadMs: 0, microphonePermissionMs: 0,
            compatibilityMs: 0, audioStartMs: 0, streamReadyMs: 0,
            outcome: "recording_ready")
        await store.record(sample, enabled: true, limit: 10)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        await store.record(sample, enabled: true, limit: 0)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testByteLimitKeepsNewestSamples() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("startup-metrics-v1.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = StartupMetricsStore(url: url, maximumBytes: 420)
        let first = StartupMetricSample(shortcutToHUDMs: 1, shortcutToRecordingReadyMs: 2,
            targetCaptureMs: 0, configLoadMs: 0, microphonePermissionMs: 0,
            compatibilityMs: 0, audioStartMs: 0, streamReadyMs: 0, outcome: "first")
        let newest = StartupMetricSample(shortcutToHUDMs: 3, shortcutToRecordingReadyMs: 4,
            targetCaptureMs: 0, configLoadMs: 0, microphonePermissionMs: 0,
            compatibilityMs: 0, audioStartMs: 0, streamReadyMs: 0, outcome: "newest")
        await store.record(first, enabled: true, limit: 100)
        await store.record(first, enabled: true, limit: 100)
        await store.record(newest, enabled: true, limit: 100)

        let samples = await store.samplesForTesting()
        XCTAssertEqual(samples.last, newest)
        XCTAssertLessThan(samples.count, 3)
    }
}

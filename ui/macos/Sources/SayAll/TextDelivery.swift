import AppKit
import ApplicationServices
import Carbon
import OSLog

@MainActor
enum TextDelivery {
    private static let logger = Logger(subsystem: "pro.leets.sayall", category: "text-delivery")

    enum Result {
        case typeCommandPosted
        case pasteCommandPosted
        case copied
        case copiedFallback
        case failed
    }

    struct Target {
        fileprivate let pid: pid_t
        fileprivate let window: AXUIElement
        fileprivate let application: NSRunningApplication
    }

    struct Focus {
        let pid: pid_t
        let element: AXUIElement
        let window: AXUIElement
        let application: NSRunningApplication
    }

    enum ElementCapability: Equatable {
        case none, editable, pasteOnlyTextArea
    }

    struct ElementFacts {
        let role: String?
        let enabled: Bool
        let nonSecureSubrole: Bool
        let valueSettable: Bool
        let writableSelectionRange: Bool
    }

    struct AccessibilityClient {
        let processID: pid_t
        let isTrusted: @MainActor () -> Bool
        let currentFocus: @MainActor () -> Focus?
        let currentTarget: @MainActor () -> Target?
        let requestAccessibility: @MainActor (Target) -> Bool
        let elementCapability: @MainActor (AXUIElement) -> ElementCapability
        let isSecureInputEnabled: @MainActor () -> Bool
        let elementsEqual: @MainActor (AXUIElement, AXUIElement) -> Bool
        let applicationsMatch: @MainActor (NSRunningApplication, NSRunningApplication) -> Bool
        let postPasteCommand: @MainActor (pid_t) -> Bool

        static let live = AccessibilityClient(
            processID: getpid(),
            isTrusted: { AXIsProcessTrusted() && CGPreflightPostEventAccess() },
            currentFocus: { TextDelivery.currentFocus() },
            currentTarget: { TextDelivery.currentTarget() },
            requestAccessibility: { TextDelivery.requestAccessibility(for: $0) },
            elementCapability: { TextDelivery.elementCapability(of: $0) },
            isSecureInputEnabled: { IsSecureEventInputEnabled() },
            elementsEqual: { CFEqual($0, $1) },
            applicationsMatch: { !$0.isTerminated && $0.isEqual($1) },
            postPasteCommand: { TextDelivery.postPasteCommand(to: $0) }
        )
    }

    static func captureTarget(client: AccessibilityClient = .live) -> Target? {
        guard client.isTrusted() else {
            logger.error("Target capture rejected: Accessibility or event-posting permission is unavailable")
            return nil
        }
        guard !client.isSecureInputEnabled() else {
            logger.error("Target capture rejected: secure keyboard input is active")
            return nil
        }
        if let focus = client.currentFocus() {
            guard focus.pid != client.processID else {
                logger.error("Target capture rejected: SayAll owns the focused element")
                return nil
            }
            guard client.elementCapability(focus.element) != .none else {
                let focusedRole = role(of: focus.element) ?? "missing"
                logger.error("Target capture rejected: role=\(focusedRole, privacy: .public) is not a text input")
                return nil
            }
            guard !client.isSecureInputEnabled() else {
                logger.error("Target capture rejected: secure keyboard input became active")
                return nil
            }
            return Target(pid: focus.pid, window: focus.window, application: focus.application)
        }
        guard let target = client.currentTarget(), target.pid != client.processID else {
            logger.error("Target capture rejected: no focused accessibility element or window")
            return nil
        }
        guard client.requestAccessibility(target) else {
            logger.error("Target capture rejected: the focused app does not expose or enable accessibility")
            return nil
        }
        guard !client.isSecureInputEnabled() else {
            logger.error("Target capture rejected: secure keyboard input became active")
            return nil
        }
        logger.info("Requested accessibility for an app with a temporarily unavailable focus tree")
        return target
    }

    /// Inserts only when a stable editable, non-secure element is focused in
    /// the original application window immediately before event delivery.
    /// Failed insertion preserves the transcript on the clipboard for recovery.
    static func deliver(
        _ text: String,
        method: OutputMethod,
        to target: Target?,
        pasteboard: NSPasteboard = .general,
        client: AccessibilityClient = .live
    ) -> Result {
        switch method {
        case .clipboard:
            return copy(text, to: pasteboard) ? .copied : .failed
        case .paste:
            guard copy(text, to: pasteboard) else { return .failed }
            guard let target = insertionTarget(target, client: client),
                  client.postPasteCommand(target.pid) else { return .copiedFallback }
            return .pasteCommandPosted
        case .type:
            guard copy(text, to: pasteboard) else { return .failed }
            guard let target = insertionTarget(target, client: client),
                  client.postPasteCommand(target.pid) else { return .copiedFallback }
            return .typeCommandPosted
        }
    }

    private static func insertionTarget(_ target: Target?, client: AccessibilityClient) -> Target? {
        guard client.isTrusted() else {
            logger.error("Insertion rejected: Accessibility or event-posting permission was revoked")
            return nil
        }
        guard !client.isSecureInputEnabled() else {
            logger.error("Insertion rejected: secure keyboard input is active")
            return nil
        }
        guard let target else {
            logger.error("Insertion rejected: no target was captured")
            return nil
        }
        guard let first = client.currentFocus(), matches(target, first, client: client),
              let second = client.currentFocus(), matches(target, second, client: client),
              client.elementsEqual(first.element, second.element) else {
            logger.error("Insertion rejected: the focused application or element changed")
            return nil
        }
        guard !client.isSecureInputEnabled() else {
            logger.error("Insertion rejected: secure keyboard input became active")
            return nil
        }
        return target
    }

    private static func matches(_ target: Target, _ focus: Focus, client: AccessibilityClient) -> Bool {
        guard focus.pid == target.pid,
              client.applicationsMatch(target.application, focus.application),
              client.elementsEqual(target.window, focus.window) else { return false }
        return client.elementCapability(focus.element) != .none
    }

    private static func currentFocus() -> Focus? {
        guard let (frontmost, pid, application) = frontmostContext() else { return nil }
        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        ) == .success,
              let element = accessibilityElement(focusedElementValue),
              processID(of: element) == pid,
              let window = window(of: element, pid: pid) else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        return Focus(pid: pid, element: element, window: window, application: frontmost)
    }

    private static func currentTarget() -> Target? {
        guard let (frontmost, pid, application) = frontmostContext() else { return nil }
        var focusedWindowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success,
           let window = accessibilityElement(focusedWindowValue),
           processID(of: window) == pid {
            return Target(pid: pid, window: window, application: frontmost)
        }
        return nil
    }

    private static func frontmostContext() -> (NSRunningApplication, pid_t, AXUIElement)? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              !frontmost.isTerminated,
              frontmost.processIdentifier != getpid() else { return nil }
        let pid = frontmost.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        return (frontmost, pid, application)
    }

    private static func window(of element: AXUIElement, pid: pid_t) -> AXUIElement? {
        for attribute in [kAXWindowAttribute, kAXTopLevelUIElementAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let window = accessibilityElement(value), processID(of: window) == pid {
                return window
            }
        }
        return nil
    }

    private static func requestAccessibility(for target: Target) -> Bool {
        guard !target.application.isTerminated,
              target.application.processIdentifier == target.pid,
              let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.isEqual(target.application) else { return false }
        let application = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(application, 0.25)

        var requested = false
        if attributeIsSettable("AXManualAccessibility", on: application) {
            _ = AXUIElementSetAttributeValue(
                application,
                "AXManualAccessibility" as CFString,
                true as CFTypeRef
            )
            requested = true
            if boolAttribute("AXManualAccessibility", on: application) == true ||
                focusedElementAvailable(in: application) {
                return true
            }
        }
        if attributeIsSettable("AXEnhancedUserInterface", on: application) {
            // Some Electron builds, including Claude Desktop, report an error
            // from this write while still enabling their accessibility tree.
            // Readiness is proven later by a successful focus query.
            _ = AXUIElementSetAttributeValue(
                application,
                "AXEnhancedUserInterface" as CFString,
                true as CFTypeRef
            )
            requested = true
        }
        return requested
    }

    private static func attributeIsSettable(_ attribute: String, on element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success &&
            settable.boolValue
    }

    private static func boolAttribute(_ attribute: String, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    private static func focusedElementAvailable(in application: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success && accessibilityElement(value) != nil
    }

    private static func accessibilityElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func processID(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        return pid
    }

    private static func elementCapability(of element: AXUIElement) -> ElementCapability {
        // Terminal buffers such as Ghostty expose a focused AXTextArea but no
        // AXEnabled value. Reject an explicit false while treating an absent
        // value as unknown; the text role, secure-input checks, and stable
        // application/window binding still gate delivery.
        let enabled = boolAttribute(kAXEnabledAttribute, on: element)
        guard enabled != false else { return .none }
        var subroleValue: CFTypeRef?
        let subroleError = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        let facts = ElementFacts(
            role: role(of: element),
            enabled: enabled ?? true,
            nonSecureSubrole: nonSecureSubrole(error: subroleError, value: subroleValue),
            valueSettable: attributeIsSettable(kAXValueAttribute, on: element),
            writableSelectionRange: hasWritableSelectionRange(element)
        )
        return classify(facts)
    }

    static func classify(_ facts: ElementFacts) -> ElementCapability {
        guard facts.enabled, facts.nonSecureSubrole else { return .none }
        let textField = facts.role == kAXTextFieldRole as String
        let textArea = facts.role == kAXTextAreaRole as String
        if facts.writableSelectionRange || ((textField || textArea) && facts.valueSettable) {
            return .editable
        }
        return textArea ? .pasteOnlyTextArea : .none
    }

    private static func hasWritableSelectionRange(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(unsafeBitCast(value, to: AXValue.self)) == .cfRange else { return false }
        return attributeIsSettable(kAXSelectedTextRangeAttribute, on: element)
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    static func nonSecureSubrole(error: AXError, value: CFTypeRef?) -> Bool {
        switch error {
        case .success:
            guard let subrole = value as? String else { return false }
            return subrole != kAXSecureTextFieldSubrole as String
        case .noValue, .attributeUnsupported:
            return true
        default:
            return false
        }
    }

    private static func postPasteCommand(to pid: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        return true
    }

    @discardableResult static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

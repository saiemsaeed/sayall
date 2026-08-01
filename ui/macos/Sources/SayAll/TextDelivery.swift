import AppKit
import ApplicationServices
import Carbon

@MainActor
enum TextDelivery {
    enum Result {
        case pasteCommandPosted
        case copied
        case failed
    }

    struct Target {
        fileprivate let pid: pid_t
        fileprivate let element: AXUIElement
        fileprivate let application: NSRunningApplication
    }

    struct Focus {
        let pid: pid_t
        let element: AXUIElement
        let application: NSRunningApplication
    }

    struct AccessibilityClient {
        let processID: pid_t
        let isTrusted: @MainActor () -> Bool
        let currentFocus: @MainActor () -> Focus?
        let isEditableAndNonSecure: @MainActor (AXUIElement) -> Bool
        let elementsEqual: @MainActor (AXUIElement, AXUIElement) -> Bool
        let applicationsMatch: @MainActor (NSRunningApplication, NSRunningApplication) -> Bool
        let postPasteCommand: @MainActor () -> Bool

        static let live = AccessibilityClient(
            processID: getpid(),
            isTrusted: { AXIsProcessTrusted() && CGPreflightPostEventAccess() },
            currentFocus: { TextDelivery.currentFocus() },
            isEditableAndNonSecure: { TextDelivery.editableAndNonSecure($0) },
            elementsEqual: { CFEqual($0, $1) },
            applicationsMatch: { !$0.isTerminated && $0.isEqual($1) },
            postPasteCommand: { TextDelivery.postPasteCommand() }
        )
    }

    static func captureTarget(client: AccessibilityClient = .live) -> Target? {
        guard client.isTrusted(),
              let focus = client.currentFocus(),
              focus.pid != client.processID,
              client.isEditableAndNonSecure(focus.element) else { return nil }
        return Target(pid: focus.pid, element: focus.element, application: focus.application)
    }

    /// Always copies the transcript. It pastes only when the original editable,
    /// non-secure element is still focused immediately before event delivery.
    static func deliver(
        _ text: String,
        to target: Target?,
        pasteboard: NSPasteboard = .general,
        client: AccessibilityClient = .live
    ) -> Result {
        guard copy(text, to: pasteboard) else { return .failed }
        guard client.isTrusted(),
              let target,
              client.isEditableAndNonSecure(target.element),
              matches(target, client.currentFocus(), client: client),
              matches(target, client.currentFocus(), client: client),
              client.postPasteCommand() else { return .copied }
        return .pasteCommandPosted
    }

    private static func matches(_ target: Target, _ focus: Focus?, client: AccessibilityClient) -> Bool {
        guard let focus,
              focus.pid == target.pid,
              client.applicationsMatch(target.application, focus.application),
              client.elementsEqual(target.element, focus.element),
              client.isEditableAndNonSecure(focus.element) else { return false }
        return true
    }

    private static func currentFocus() -> Focus? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              !frontmost.isTerminated,
              frontmost.processIdentifier != getpid() else { return nil }
        let pid = frontmost.processIdentifier
        let system = AXUIElementCreateSystemWide()
        var focusedApplicationValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApplicationValue
        ) == .success,
              let application = accessibilityElement(focusedApplicationValue),
              processID(of: application) == pid else { return nil }
        AXUIElementSetMessagingTimeout(application, 0.25)
        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        ) == .success,
              let element = accessibilityElement(focusedElementValue),
              processID(of: element) == pid else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        return Focus(pid: pid, element: element, application: frontmost)
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

    private static func editableAndNonSecure(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String,
              role == kAXTextFieldRole as String || role == kAXTextAreaRole as String else { return false }

        var subroleValue: CFTypeRef?
        let subroleError = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleValue)
        guard nonSecureSubrole(error: subroleError, value: subroleValue) else { return false }

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success else {
            return false
        }
        return settable.boolValue
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

    private static func postPasteCommand() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        return true
    }

    @discardableResult static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

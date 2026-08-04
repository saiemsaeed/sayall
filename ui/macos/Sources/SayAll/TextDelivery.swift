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
        fileprivate enum Kind { case editableElement, pasteOnlySurface }
        fileprivate let pid: pid_t
        fileprivate let element: AXUIElement
        fileprivate let application: NSRunningApplication
        fileprivate let kind: Kind
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
        let isPasteOnlySurface: @MainActor (AXUIElement) -> Bool
        let isSecureInputEnabled: @MainActor () -> Bool
        let elementsEqual: @MainActor (AXUIElement, AXUIElement) -> Bool
        let applicationsMatch: @MainActor (NSRunningApplication, NSRunningApplication) -> Bool
        let postPasteCommand: @MainActor () -> Bool

        static let live = AccessibilityClient(
            processID: getpid(),
            isTrusted: { AXIsProcessTrusted() && CGPreflightPostEventAccess() },
            currentFocus: { TextDelivery.currentFocus() },
            isEditableAndNonSecure: { TextDelivery.editableAndNonSecure($0) },
            isPasteOnlySurface: { TextDelivery.pasteOnlySurface($0) },
            isSecureInputEnabled: { IsSecureEventInputEnabled() },
            elementsEqual: { CFEqual($0, $1) },
            applicationsMatch: { !$0.isTerminated && $0.isEqual($1) },
            postPasteCommand: { TextDelivery.postPasteCommand() }
        )
    }

    static func captureTarget(client: AccessibilityClient = .live) -> Target? {
        guard client.isTrusted() else {
            logger.error("Target capture rejected: Accessibility or event-posting permission is unavailable")
            return nil
        }
        guard let focus = client.currentFocus() else {
            logger.error("Target capture rejected: no focused accessibility element")
            return nil
        }
        guard focus.pid != client.processID else {
            logger.error("Target capture rejected: SayAll owns the focused element")
            return nil
        }
        let kind: Target.Kind
        if client.isEditableAndNonSecure(focus.element) {
            kind = .editableElement
        } else if client.isPasteOnlySurface(focus.element), !client.isSecureInputEnabled() {
            // Some terminal surfaces expose a read-only text area for their
            // displayed buffer. Keep the same fail-closed app/element binding,
            // then use one paste command while that exact surface remains focused.
            kind = .pasteOnlySurface
        } else {
            let focusedRole = role(of: focus.element) ?? "missing"
            let secureInput = client.isSecureInputEnabled()
            logger.error("Target capture rejected: role=\(focusedRole, privacy: .public) secure-input=\(secureInput, privacy: .public)")
            return nil
        }
        return Target(pid: focus.pid, element: focus.element, application: focus.application, kind: kind)
    }

    /// Inserts only when the original editable, non-secure element is still
    /// focused immediately before event delivery. Failed insertion preserves
    /// the transcript on the clipboard for manual recovery.
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
            return canInsert(to: target, client: client) && client.postPasteCommand()
                ? .pasteCommandPosted : .copiedFallback
        case .type:
            guard copy(text, to: pasteboard) else { return .failed }
            return canInsert(to: target, client: client) && client.postPasteCommand()
                ? .typeCommandPosted : .copiedFallback
        }
    }

    private static func canInsert(to target: Target?, client: AccessibilityClient) -> Bool {
        guard client.isTrusted() else {
            logger.error("Insertion rejected: Accessibility or event-posting permission was revoked")
            return false
        }
        guard !client.isSecureInputEnabled() else {
            logger.error("Insertion rejected: secure keyboard input is active")
            return false
        }
        guard let target else {
            logger.error("Insertion rejected: no target was captured")
            return false
        }
        guard matches(target, client.currentFocus(), client: client),
              matches(target, client.currentFocus(), client: client) else {
            logger.error("Insertion rejected: the focused application or element changed")
            return false
        }
        return true
    }

    private static func matches(_ target: Target, _ focus: Focus?, client: AccessibilityClient) -> Bool {
        guard let focus,
              focus.pid == target.pid,
              client.applicationsMatch(target.application, focus.application),
              client.elementsEqual(target.element, focus.element) else { return false }
        switch target.kind {
        case .editableElement: return client.isEditableAndNonSecure(focus.element)
        case .pasteOnlySurface: return client.isPasteOnlySurface(focus.element)
        }
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
        guard let role = role(of: element),
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

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func pasteOnlySurface(_ element: AXUIElement) -> Bool {
        guard let elementRole = role(of: element) else { return false }
        guard elementRole == kAXTextAreaRole as String else { return false }
        var subroleValue: CFTypeRef?
        let subroleError = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )
        return nonSecureSubrole(error: subroleError, value: subroleValue)
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

import AppKit
import ApplicationServices
import Carbon

enum TextDelivery {
    enum Result {
        case pasteCommandPosted
        case copied
        case failed
    }

    /// Copies the transcript, then pastes it at the cursor's current location.
    static func deliver(_ text: String) -> Result {
        guard copy(text) else { return .failed }
        guard CGPreflightPostEventAccess(),
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) else {
            return .copied
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
        return .pasteCommandPosted
    }

    @discardableResult static func copy(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

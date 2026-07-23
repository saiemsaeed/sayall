import AppKit
import AVFoundation
import Carbon

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!, coordinator: Coordinator!
    private var hotKey: EventHotKeyRef?
    private var accessibilityTimer: Timer?
    private var accessibilityChecksRemaining = 0
    private let statusPanel = StatusPanel()
    private var shortcutAvailable = false

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.machineHardwareName == "arm64" else { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory); AudioCapture.removeStaleFiles()
        coordinator = Coordinator(
            configuration: ConfigurationLoader(),
            changed: { [weak self] in self?.refreshStatus() }
        )
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "SayAll")
        statusItem.button?.title = "SayAll"
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "SayAll"
        rebuildMenu(); registerShortcut()
        if !CGPreflightPostEventAccess() { requestAccessibility() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancel), name: NSWorkspace.willSleepNotification, object: nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        accessibilityTimer?.invalidate()
        coordinator.cancel()
        AudioCapture.removeStaleFiles()
    }
    @objc private func cancel() { coordinator.cancel() }
    @objc private func trigger() { coordinator.trigger() }
    @objc private func openMicSettings() { openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
    @objc private func openAXSettings() { openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") }
    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        accessibilityChecksRemaining = 240
        monitorAccessibility()
    }
    private func openSystemSettings(_ value: String) { if let url = URL(string: value) { NSWorkspace.shared.open(url) } }
    private func monitorAccessibility() {
        guard accessibilityTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.accessibilityChecksRemaining -= 1
                if CGPreflightPostEventAccess() || self.accessibilityChecksRemaining <= 0 {
                    timer.invalidate()
                    self.accessibilityTimer = nil
                    self.rebuildMenu()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }
    private func rebuildMenu() {
        guard statusItem != nil else { return }; let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let product = NSMenuItem(title: "SayAll \(version)", action: nil, keyEquivalent: ""); product.isEnabled = false; menu.addItem(product)
        let state = NSMenuItem(title: "State: \(coordinator.state.rawValue.capitalized)", action: nil, keyEquivalent: ""); state.isEnabled = false; menu.addItem(state)
        if !shortcutAvailable {
            let conflict = NSMenuItem(title: "Control+/ unavailable — use this menu", action: nil, keyEquivalent: "")
            conflict.isEnabled = false; menu.addItem(conflict)
        }
        menu.addItem(withTitle: coordinator.state == .recording ? "Stop Dictation" : "Start Dictation", action: #selector(trigger), keyEquivalent: "")
        menu.addItem(.separator())
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        menu.addItem(withTitle: "Microphone: \(String(describing: mic)) — Open Settings", action: #selector(openMicSettings), keyEquivalent: "")
        let accessibilityGranted = CGPreflightPostEventAccess()
        menu.addItem(
            withTitle: accessibilityGranted ? "Accessibility: Granted — Open Settings" : "Accessibility: Not Granted — Request Access",
            action: accessibilityGranted ? #selector(openAXSettings) : #selector(requestAccessibility),
            keyEquivalent: ""
        )
        menu.addItem(.separator()); menu.addItem(withTitle: "Quit SayAll", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }
    private func refreshStatus() {
        rebuildMenu()
        statusPanel.update(state: coordinator.state, message: coordinator.message, audioLevel: coordinator.audioLevel)
    }
    private func registerShortcut() {
        let id = EventHotKeyID(signature: OSType(0x53415941), id: 1)
        shortcutAvailable = RegisterEventHotKey(UInt32(kVK_ANSI_Slash), UInt32(controlKey), id, GetApplicationEventTarget(), 0, &hotKey) == noErr
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }; Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().trigger(); return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        rebuildMenu()
    }
}

private extension ProcessInfo {
    var machineHardwareName: String { var size = 0; sysctlbyname("hw.machine", nil, &size, nil, 0); var chars = [CChar](repeating: 0, count: size); sysctlbyname("hw.machine", &chars, &size, nil, 0); return String(cString: chars) }
}

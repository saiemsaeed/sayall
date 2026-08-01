import AppKit
import AVFoundation
import Carbon
import UserNotifications

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!, coordinator: Coordinator!
    private var hotKey: EventHotKeyRef?
    private var accessibilityTimer: Timer?
    private var accessibilityChecksRemaining = 0
    private let statusPanel = StatusPanel()
    private let errorNotifier = ErrorNotifier()
    private var shortcutAvailable = false
    private var statusGeneration = 0
    private var errorNotificationTask: Task<Void, Never>?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.machineHardwareName == "arm64" else { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory); AudioCapture.removeStaleFiles()
        errorNotifier.prepare()
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
        statusGeneration += 1
        let generation = statusGeneration
        errorNotificationTask?.cancel()
        statusPanel.update(state: coordinator.state, message: coordinator.message, audioLevel: coordinator.audioLevel)
        guard coordinator.state == .error else { return }
        let message = coordinator.message
        errorNotificationTask = Task { [weak self] in
            guard let self, await errorNotifier.notify(message), !Task.isCancelled,
                  statusGeneration == generation,
                  coordinator.state == .error,
                  coordinator.message == message else { return }
            statusPanel.update(state: .idle, message: "", audioLevel: 0)
        }
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

@MainActor
private final class ErrorNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var preparation: Task<Void, Never>?

    override init() {
        super.init()
        center.delegate = self
    }

    func prepare() {
        guard preparation == nil else { return }
        preparation = Task { [center] in
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
        }
    }

    func notify(_ message: String) async -> Bool {
        if let preparation { await preparation.value }
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional].contains(settings.authorizationStatus),
              settings.alertSetting == .enabled else { return false }
        let content = UNMutableNotificationContent()
        content.title = "SayAll error"
        content.body = message
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            return true
        } catch {
            return false
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

private extension ProcessInfo {
    var machineHardwareName: String { var size = 0; sysctlbyname("hw.machine", nil, &size, nil, 0); var chars = [CChar](repeating: 0, count: size); sysctlbyname("hw.machine", &chars, &size, nil, 0); return String(cString: chars) }
}

import AppKit
import AVFoundation
import Carbon
import SayAllControl
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
    private var menuState: HostControlState?
    private var errorNotificationTask: Task<Void, Never>?
    private let controlServer = ControlServer()
    private var ownsInstance = false
    private var cliInstaller: Process?
    private var audioDeviceMonitor: AudioInputDeviceMonitor?

    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.machineHardwareName == "arm64" else { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        coordinator = Coordinator(
            configuration: ConfigurationLoader(),
            changed: { [weak self] in self?.refreshStatus() }
        )
        do { try controlServer.start(state: { [weak self] in
            self?.coordinator.hostControlState ?? .error
        }) { [weak self] method in
            self?.coordinator.handleControl(method) ?? ControlResponse(ok: false, state: "unavailable", error: "app unavailable")
        } } catch {
            NSApp.terminate(nil)
            return
        }
        ownsInstance = true
        AudioCapture.removeStaleFiles()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "SayAll")
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "SayAll"
        rebuildMenu(); registerShortcut()
        audioDeviceMonitor = AudioInputDeviceMonitor { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.coordinator.state == .idle else { return }
                    self.rebuildMenu()
                }
            }
        }
        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sayall-process")
        Task.detached(priority: .utility) {
            _ = try? await HelperRunner(executableURL: helperURL).compatibilityPreflight()
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(cancel), name: NSWorkspace.willSleepNotification, object: nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        guard ownsInstance else { return }
        accessibilityTimer?.invalidate()
        coordinator.cancel()
        controlServer.stop()
        AudioCapture.removeStaleFiles()
        ownsInstance = false
    }
    @objc private func cancel() { coordinator.cancel() }
    @objc private func trigger() { coordinator.trigger(source: .menu) }
    @objc private func reloadConfiguration() {
        let response = coordinator.handleControl(.reload)
        let alert = NSAlert()
        alert.messageText = response.ok ? "Configuration reloaded" : "Could not reload configuration"
        alert.informativeText = response.ok
            ? "Your changes will be used for the next dictation."
            : (response.error?.replacingOccurrences(of: "error: ", with: "", options: .anchored)
                ?? "The configuration could not be loaded.")
        alert.alertStyle = response.ok ? .informational : .warning
        alert.runModal()
    }
    private func triggerShortcut() { coordinator.trigger(source: .shortcut) }
    @objc private func selectMicrophone(_ sender: NSMenuItem) {
        guard coordinator.state == .idle else { return }
        MicrophoneSelection.uniqueID = sender.representedObject as? String
        rebuildMenu()
    }
    @objc private func installCommandLineTool() {
        guard cliInstaller == nil else {
            showInstallResult("A command line tool operation is already in progress.")
            return
        }
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sayall").path
        let target = "/usr/local/bin/sayall"
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target) {
            if installedCLIIsCurrent(destination: destination, target: target, cli: cli) {
                showInstallResult("The current SayAll command line tool is already installed.")
            } else {
                showInstallResult("\(target) is already a symlink to another location and was not changed.")
            }
            return
        }
        if FileManager.default.fileExists(atPath: target) {
            showInstallResult("\(target) already exists and was not changed. Remove it manually only if you own it.")
            return
        }
        let script = """
        on run argv
          set sourcePath to item 1 of argv
          set targetPath to item 2 of argv
          do shell script "/usr/bin/install -d -m 755 /usr/local/bin && /bin/test ! -e " & quoted form of targetPath & " && /bin/test ! -L " & quoted form of targetPath & " && /bin/ln -sh " & quoted form of sourcePath & " " & quoted form of targetPath with administrator privileges
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, cli, target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self else { return }
                self.cliInstaller = nil
                guard process.terminationStatus == 0,
                      let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target),
                      self.installedCLIIsCurrent(destination: destination, target: target, cli: cli) else {
                    self.showInstallResult("The command line tool was not installed or could not be verified.")
                    self.rebuildMenu()
                    return
                }
                self.showInstallResult("Installed \(target). Open a new Terminal window and run ‘sayall version’.")
                self.rebuildMenu()
            }
        }
        do {
            cliInstaller = process
            try process.run()
        } catch {
            cliInstaller = nil
            showInstallResult("Could not start the macOS administrator authorization prompt.")
        }
    }
    @objc private func removeCommandLineTool() {
        guard cliInstaller == nil else {
            showInstallResult("A command line tool operation is already in progress.")
            return
        }
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sayall").path
        let target = "/usr/local/bin/sayall"
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target),
              destination == cli else {
            showInstallResult("\(target) is not the command line tool installed by this SayAll app and was not changed.")
            return
        }
        let script = """
        on run argv
          set sourcePath to item 1 of argv
          set targetPath to item 2 of argv
          do shell script "/bin/test -L " & quoted form of targetPath & " && /bin/test \"$(/usr/bin/readlink " & quoted form of targetPath & ")\" = " & quoted form of sourcePath & " && /bin/rm " & quoted form of targetPath with administrator privileges
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, cli, target]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self else { return }
                self.cliInstaller = nil
                if process.terminationStatus == 0 && !FileManager.default.fileExists(atPath: target) {
                    self.showInstallResult("Removed \(target).")
                } else {
                    self.showInstallResult("The command line tool was not removed or could not be verified.")
                }
                self.rebuildMenu()
            }
        }
        do {
            cliInstaller = process
            try process.run()
        } catch {
            cliInstaller = nil
            showInstallResult("Could not start the macOS administrator authorization prompt.")
        }
    }
    private func installedCLIIsCurrent(destination: String, target: String, cli: String) -> Bool {
        let resolved = destination.hasPrefix("/") ? URL(fileURLWithPath: destination) :
            URL(fileURLWithPath: target).deletingLastPathComponent().appendingPathComponent(destination)
        return resolved.standardizedFileURL.resolvingSymlinksInPath().path ==
            URL(fileURLWithPath: cli).resolvingSymlinksInPath().path
    }
    private func showInstallResult(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Install Command Line Tool"; alert.informativeText = message
        alert.addButton(withTitle: "OK"); alert.runModal()
    }
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
        let toggle = NSMenuItem(
            title: coordinator.state == .recording ? "Stop Dictation" : "Start Dictation",
            action: #selector(trigger),
            keyEquivalent: ""
        )
        toggle.target = self
        toggle.isEnabled = coordinator.state == .idle || coordinator.state == .recording
        menu.addItem(toggle)
        let reload = NSMenuItem(title: "Reload Configuration", action: #selector(reloadConfiguration), keyEquivalent: "")
        reload.target = self
        reload.isEnabled = coordinator.state == .idle
        menu.addItem(reload)
        menu.addItem(.separator())
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sayall").path
        let target = "/usr/local/bin/sayall"
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: target), destination == cli {
            menu.addItem(withTitle: "Remove Command Line Tool…", action: #selector(removeCommandLineTool), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "Install Command Line Tool…", action: #selector(installCommandLineTool), keyEquivalent: "")
        }
        menu.addItem(.separator())
        let devices = AudioInputDevices.available()
        let selectedMicrophone = MicrophoneSelection.uniqueID
        let microphoneItem = NSMenuItem(title: "Input Device", action: nil, keyEquivalent: "")
        let microphoneMenu = NSMenu(title: "Input Device")
        let systemDefaultName = devices.first(where: \.isDefault)?.name ?? "Unavailable"
        let systemDefaultItem = NSMenuItem(
            title: "System Default (\(systemDefaultName))",
            action: #selector(selectMicrophone(_:)),
            keyEquivalent: ""
        )
        systemDefaultItem.target = self
        systemDefaultItem.state = selectedMicrophone == nil ? .on : .off
        systemDefaultItem.isEnabled = coordinator.state == .idle
        microphoneMenu.addItem(systemDefaultItem)
        microphoneMenu.addItem(.separator())
        for device in devices {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uniqueID
            item.state = selectedMicrophone == device.uniqueID ? .on : .off
            item.isEnabled = coordinator.state == .idle
            microphoneMenu.addItem(item)
        }
        if let selectedMicrophone, !devices.contains(where: { $0.uniqueID == selectedMicrophone }) {
            microphoneMenu.addItem(.separator())
            let unavailable = NSMenuItem(title: "Selected device is unavailable", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            microphoneMenu.addItem(unavailable)
        }
        microphoneMenu.addItem(.separator())
        let microphoneSettings = NSMenuItem(
            title: "Microphone Privacy Settings…",
            action: #selector(openMicSettings),
            keyEquivalent: ""
        )
        microphoneSettings.target = self
        microphoneMenu.addItem(microphoneSettings)
        microphoneItem.submenu = microphoneMenu
        menu.addItem(microphoneItem)
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
        statusGeneration += 1
        let generation = statusGeneration
        errorNotificationTask?.cancel()
        let startupPresented = statusPanel.update(
            state: coordinator.state,
            message: coordinator.message,
            audioLevel: coordinator.audioLevel,
            showTimer: coordinator.showTimer
        )
        if startupPresented { coordinator.markHUDPresented() }
        if menuState != coordinator.hostControlState {
            menuState = coordinator.hostControlState
            rebuildMenu()
        }
        if let warning = coordinator.takePendingWarning() {
            Task { [errorNotifier] in
                _ = await errorNotifier.notify(title: "SayAll warning", message: warning)
            }
        }
        guard coordinator.state == .error else { return }
        let message = coordinator.message
        errorNotificationTask = Task { [weak self] in
            guard let self, await errorNotifier.notify(title: "SayAll error", message: message), !Task.isCancelled,
                  statusGeneration == generation,
                  coordinator.state == .error,
                  coordinator.message == message else { return }
            statusPanel.update(state: .idle, message: "", audioLevel: 0, showTimer: true)
        }
    }
    private func registerShortcut() {
        let id = EventHotKeyID(signature: OSType(0x53415941), id: 1)
        shortcutAvailable = RegisterEventHotKey(UInt32(kVK_ANSI_Slash), UInt32(controlKey), id, GetApplicationEventTarget(), 0, &hotKey) == noErr
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue().triggerShortcut()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        rebuildMenu()
    }
}

@MainActor
private final class ErrorNotifier: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func notify(title: String, message: String) async -> Bool {
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return false }
            settings = await center.notificationSettings()
        }
        guard [.authorized, .provisional].contains(settings.authorizationStatus),
              settings.alertSetting == .enabled else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
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

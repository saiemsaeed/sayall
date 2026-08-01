import AppKit
import Darwin
import Foundation
import MachO
import SayAllControl

enum CLICommand: Equatable { case version, status, toggle, configInit }
enum CLIError: Error, Equatable { case usage, exists }

enum CLI {
    static func parse(_ arguments: [String]) throws -> CLICommand {
        switch arguments {
        case ["version"], ["--version"]: return .version
        case ["status"]: return .status
        case ["toggle"]: return .toggle
        case ["config", "init"]: return .configInit
        default: throw CLIError.usage
        }
    }
    static func configURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("sayall/config.json")
        }
        return home.appendingPathComponent(".config/sayall/config.json")
    }
    static func initializeConfig(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        let url = configURL(home: home, environment: environment), directory = url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: directory.path) {
            var information = stat()
            guard lstat(directory.path, &information) == 0,
                  information.st_uid == geteuid(),
                  information.st_mode & S_IFMT == S_IFDIR else { throw POSIXError(.EACCES) }
        } else {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            if errno == EEXIST { throw CLIError.exists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let data = Data("""
        {
          "stt": {
            "provider": "deepgram", "api_key": "", "model": "nova-3",
            "language": "en", "region": "global", "streaming": true,
            "stream_finalize_timeout_ms": 2000
          },
          "llm": {
            "provider": "groq", "api_key": "", "model": "llama-3.1-8b-instant",
            "base_url": "https://api.groq.com/openai/v1/chat/completions", "enabled": true
          },
          "output": {"method": "type", "trailing_space": true},
          "recording": {"max_seconds": 300, "min_ms": 300, "source": ""},
          "metrics": {"enabled": true, "history_max_entries": 1000, "expose_api": true},
          "hud": {"show_timer": true},
          "notifications": true,
          "verbose": false
        }

        """.utf8)
        defer { close(fd) }
        do { try ControlSocket.writeAll(data, to: fd, deadline: ControlSocket.deadline(afterMilliseconds: 1_000)) }
        catch { unlink(url.path); throw error }
        return url
    }
    static var containingAppURL: URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }
    static var version: String {
        guard let app = containingAppURL, let bundle = Bundle(url: app),
              let value = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return "development" }
        return value
    }
}

@main enum SayAllCLI {
    static func main() {
        do {
            switch try CLI.parse(Array(CommandLine.arguments.dropFirst())) {
            case .version: print("sayall \(CLI.version)")
            case .configInit:
                let url = try CLI.initializeConfig()
                print("Created \(url.path). Set stt.api_key before recording; keep this file private.")
            case .status:
                let response = try ControlSocket.exchange(.init(method: .status)); print(response.state)
                if !response.ok { fputs("sayall: \(response.error ?? "request failed")\n", stderr); exit(1) }
            case .toggle:
                var ready = try? ControlSocket.exchange(.init(method: .status))
                if ready == nil {
                    guard let app = CLI.containingAppURL else { throw POSIXError(.ENOENT) }
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = false
                    configuration.allowsRunningApplicationSubstitution = false
                    let semaphore = DispatchSemaphore(value: 0)
                    NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in semaphore.signal() }
                    _ = semaphore.wait(timeout: .now() + 2)
                    let deadline = Date().addingTimeInterval(5)
                    repeat {
                        ready = try? ControlSocket.exchange(.init(method: .status), timeoutMilliseconds: 500)
                        if ready != nil { break }; Thread.sleep(forTimeInterval: 0.1)
                    } while Date() < deadline
                }
                guard ready != nil else { throw POSIXError(.ETIMEDOUT) }
                let response = try ControlSocket.exchange(.init(method: .toggle))
                print(response.state)
                if !response.ok { fputs("sayall: \(response.error ?? "request failed")\n", stderr); exit(1) }
            }
        } catch CLIError.usage {
            fputs("usage: sayall {version|--version|status|toggle|config init}\n", stderr); exit(2)
        } catch CLIError.exists {
            fputs("sayall: \(CLI.configURL().path) already exists; not overwritten\n", stderr); exit(1)
        } catch {
            let command = CommandLine.arguments.dropFirst().first
            fputs("sayall: \(command == "status" ? "not running" : "request failed")\n", stderr); exit(1)
        }
    }
}

import Darwin
import Foundation
import SayAllControl

enum ControlRoute: Equatable {
    case v1(ControlMethod)
    case v2(HostControlMethod)
    case invalid
}

func decodeControlRoute(_ data: Data) -> ControlRoute {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let version = object["version"] as? Int else { return .invalid }
    if version == 1, let request = try? JSONDecoder().decode(ControlRequest.self, from: data) {
        return .v1(request.method)
    }
    if version == 2, let request = try? JSONDecoder().decode(HostControlRequest.self, from: data) {
        return .v2(request.method)
    }
    return .invalid
}

@MainActor
func dispatchControlRoute<T>(_ route: ControlRoute, handler: @MainActor (ControlMethod) -> T) -> T? {
    switch route {
    case .v1(let method): return handler(method)
    case .v2(let method):
        switch method {
        case .status: return handler(.status)
        case .toggle: return handler(.toggle)
        case .reload: return handler(.reload)
        }
    case .invalid: return nil
    }
}

/// A same-login-session endpoint. Directory and socket modes plus getpeereid
/// restrict control to this UID; processes already running as the user are trusted.
final class ControlServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "pro.leets.sayall.control", qos: .userInitiated)
    private var lockDescriptor: Int32 = -1
    private var source: DispatchSourceRead?
    private var sourceStopped: DispatchSemaphore?
    private var ownsSocket = false

    func start(state: @escaping @MainActor () -> HostControlState,
               handler: @escaping @MainActor (ControlMethod) -> ControlResponse) throws {
        let directory = ControlSocket.directoryURL
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
        let lock = open(directory.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            if lock >= 0 { close(lock) }
            throw POSIXError(.EADDRINUSE)
        }
        lockDescriptor = lock
        do {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.EIO) }
            var keepDescriptor = false
            defer { if !keepDescriptor { close(fd) } }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var address = try ControlSocket.address(path: ControlSocket.url.path)
            var result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 && errno == EADDRINUSE {
                var information = stat()
                guard lstat(ControlSocket.url.path, &information) == 0,
                      information.st_uid == geteuid(),
                      information.st_mode & S_IFMT == S_IFSOCK else {
                    throw POSIXError(.EADDRINUSE)
                }
                try FileManager.default.removeItem(at: ControlSocket.url)
                result = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            ownsSocket = true
            guard chmod(ControlSocket.url.path, 0o600) == 0, listen(fd, 8) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            keepDescriptor = true
            let stopped = DispatchSemaphore(value: 0)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.accept(on: fd, state: state, handler: handler) }
            source.setCancelHandler { close(fd); stopped.signal() }
            sourceStopped = stopped
            self.source = source
            source.resume()
        } catch {
            cleanupEndpoint()
            throw error
        }
    }

    private func accept(on listener: Int32, state: @escaping @MainActor () -> HostControlState,
                        handler: @escaping @MainActor (ControlMethod) -> ControlResponse) {
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        queue.async {
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            let flags = fcntl(client, F_GETFL)
            guard flags >= 0, fcntl(client, F_SETFL, flags | O_NONBLOCK) == 0 else { close(client); return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { close(client); return }
            var noPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            let deadline = ControlSocket.deadline(afterMilliseconds: 1_000)
            guard let line = try? ControlSocket.readLine(from: client, deadline: deadline),
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let requestVersion = object["version"] as? Int else { close(client); return }
            let route = decodeControlRoute(line)
            switch route {
            case .v2:
                Task { @MainActor in
                    guard let legacy = dispatchControlRoute(route, handler: handler) else { close(client); return }
                    let state = HostControlState(rawValue: legacy.state) ?? .error
                    let response = HostControlResponse(ok: legacy.ok, state: state,
                        error: legacy.ok ? nil : hostV2Failure(legacy.error ?? "Request failed"))
                    self.writeV2(response, to: client, deadline: deadline)
                }
            case .v1:
                Task { @MainActor in
                    guard let response = dispatchControlRoute(route, handler: handler) else { close(client); return }
                    guard let output = try? ControlSocket.encodeFrame(response) else { close(client); return }
                    self.queue.async {
                        try? ControlSocket.writeAll(output, to: client, deadline: deadline)
                        close(client)
                    }
                }
            case .invalid:
                if requestVersion == 2 {
                    Task { @MainActor in
                        self.writeV2(.init(ok: false, state: state(),
                            error: .init(code: "invalid_request", message: "Malformed request")), to: client, deadline: deadline)
                    }
                } else if requestVersion != 1 {
                    Task { @MainActor in
                        self.writeV2(.init(ok: false, state: state(),
                            error: .init(code: "incompatible_version", message: "Unsupported control protocol version")),
                            to: client, deadline: deadline)
                    }
                } else {
                    close(client)
                }
            }
        }
    }

    private func writeV2(_ response: HostControlResponse, to client: Int32, deadline: UInt64) {
        guard let output = try? ControlSocket.encodeFrame(response) else { close(client); return }
        queue.async {
            try? ControlSocket.writeAll(output, to: client, deadline: deadline)
            close(client)
        }
    }

    func stop() {
        if let source {
            source.cancel()
            sourceStopped?.wait()
        }
        source = nil
        sourceStopped = nil
        cleanupEndpoint()
    }
    private func cleanupEndpoint() {
        if ownsSocket { try? FileManager.default.removeItem(at: ControlSocket.url); ownsSocket = false }
        if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); close(lockDescriptor); lockDescriptor = -1 }
    }
    deinit { stop() }
}

func hostV2Failure(_ legacy: String) -> HostControlError {
    if legacy.hasPrefix("busy: ") {
        return .init(code: "busy", message: String(legacy.dropFirst("busy: ".count)))
    }
    if legacy.hasPrefix("error: ") {
        return .init(code: "unavailable", message: String(legacy.dropFirst("error: ".count)))
    }
    return .init(code: legacy.hasPrefix("busy") ? "busy" : "unavailable", message: legacy)
}

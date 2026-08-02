import Darwin
import Foundation

public enum ControlMethod: String, Codable { case status, toggle }

public struct ControlRequest: Codable, Equatable {
    public let version: Int
    public let method: ControlMethod
    public init(version: Int = 1, method: ControlMethod) { self.version = version; self.method = method }
}

public struct ControlResponse: Codable, Equatable {
    public let version: Int
    public let ok: Bool
    public let state: String
    public let error: String?
    public init(version: Int = 1, ok: Bool, state: String, error: String? = nil) {
        self.version = version; self.ok = ok; self.state = state; self.error = error
    }
}

public enum HostControlMethod: String, Codable { case status, toggle }
public enum HostControlState: String, Codable, CaseIterable {
    case idle, starting, recording, stopping, processing, delivering, success, error, cancelled
}
public struct HostControlRequest: Codable, Equatable {
    public let version: Int
    public let method: HostControlMethod
    public init(version: Int, method: HostControlMethod) { self.version = version; self.method = method }
}
public struct HostControlError: Codable, Equatable {
    public let code: String
    public let message: String
    public init(code: String, message: String) { self.code = code; self.message = message }
}
public struct HostControlResponse: Codable, Equatable {
    public let version: Int
    public let ok: Bool
    public let state: HostControlState
    public let error: HostControlError?
    public init(version: Int = 2, ok: Bool, state: HostControlState, error: HostControlError? = nil) {
        self.version = version; self.ok = ok; self.state = state; self.error = error
    }
    public func validate() throws {
        guard version == 2, ok != (error != nil) else { throw POSIXError(.EPROTO) }
    }
}

public enum ControlSocket {
    public static let maximumFrameBytes = 64 * 1_024

    public static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SayAll/control", isDirectory: true)
    }
    public static var url: URL { directoryURL.appendingPathComponent("control.sock") }

    public static func address(path: String) throws -> sockaddr_un {
        guard path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            for (index, byte) in path.utf8.enumerated() { bytes[index] = byte }
            bytes[path.utf8.count] = 0
        }
        return address
    }

    public static func deadline(afterMilliseconds milliseconds: Int32) -> UInt64 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec) + UInt64(milliseconds) * 1_000_000
    }

    public static func connect(deadline: UInt64) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
            var address = try address(path: url.path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                try wait(fd: fd, events: Int16(POLLOUT), deadline: deadline)
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0, socketError == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: socketError) ?? .EIO)
                }
            }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { throw POSIXError(.EACCES) }
            var noPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
            return fd
        } catch { close(fd); throw error }
    }

    public static func exchange(_ request: ControlRequest, timeoutMilliseconds: Int32 = 1_000) throws -> ControlResponse {
        let deadline = deadline(afterMilliseconds: timeoutMilliseconds)
        let fd = try connect(deadline: deadline)
        defer { close(fd) }
        let data = try encodeFrame(request)
        try writeAll(data, to: fd, deadline: deadline)
        let response = try JSONDecoder().decode(ControlResponse.self, from: readLine(from: fd, deadline: deadline))
        guard response.version == 1 else { throw POSIXError(.EPROTO) }
        return response
    }

    public static func encodeFrame<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0a)
        guard data.count <= maximumFrameBytes else { throw POSIXError(.EMSGSIZE) }
        return data
    }

    public static func readLine(from fd: Int32, deadline: UInt64) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while result.count <= maximumFrameBytes {
            try wait(fd: fd, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximumFrameBytes + 1 - result.count))
            if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            guard count > 0 else { throw POSIXError(count == 0 ? .ECONNRESET : POSIXErrorCode(rawValue: errno) ?? .EIO) }
            result.append(contentsOf: buffer[..<Int(count)])
            if let newline = result.firstIndex(of: 0x0a) {
                guard newline == result.index(before: result.endIndex) else { throw POSIXError(.EPROTO) }
                guard result.count <= maximumFrameBytes else { throw POSIXError(.EMSGSIZE) }
                result.removeLast()
                return result
            }
        }
        throw POSIXError(.EMSGSIZE)
    }

    public static func writeAll(_ data: Data, to fd: Int32, deadline: UInt64) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                try wait(fd: fd, events: Int16(POLLOUT), deadline: deadline)
                let count = Darwin.write(fd, base.advanced(by: written), bytes.count - written)
                if count < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += count
            }
        }
    }

    private static func wait(fd: Int32, events: Int16, deadline: UInt64) throws {
        while true {
            let remaining = remainingMilliseconds(until: deadline)
            guard remaining > 0 else { throw POSIXError(.ETIMEDOUT) }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, remaining)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw POSIXError(result == 0 ? .ETIMEDOUT : POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw POSIXError(.EBADF) }
            guard descriptor.revents & Int16(POLLERR | POLLHUP) == 0 || descriptor.revents & events != 0 else {
                throw POSIXError(.ECONNRESET)
            }
            return
        }
    }

    private static func remainingMilliseconds(until deadline: UInt64) -> Int32 {
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC, &time)
        let now = UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
        guard deadline > now else { return 0 }
        return Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
    }
}

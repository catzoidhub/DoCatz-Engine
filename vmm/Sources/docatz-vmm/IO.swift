import Foundation

// Small pieces shared by the rest: JSON lines, the log, BSD sockets and joining two file descriptors.

typealias JSON = [String: Any]

enum Out {
    private static let lock = NSLock()

    /// One event line on stdout (the contract's §6), flushed at once.
    static func event(_ obj: JSON) {
        guard let line = encode(obj) else { return }
        lock.lock()
        FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
        lock.unlock()
    }

    /// The helper's own log on stderr.
    static func log(_ text: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
        lock.lock()
        FileHandle.standardError.write("\(stamp) \(text)\n".data(using: .utf8)!)
        lock.unlock()
    }
}

func encode(_ obj: Any) -> String? {
    guard JSONSerialization.isValidJSONObject(obj), let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
    return String(data: data, encoding: .utf8)
}

func decode(_ line: Substring) -> JSON? {
    guard let data = line.data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? JSON
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

/// Reads newline-separated lines from a file descriptor (blocking; run it on its own thread).
final class LineReader {
    private let fd: Int32
    private var buffer = Data()

    init(fd: Int32) { self.fd = fd }

    func next() -> Substring? {
        while true {
            if let i = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<i]
                buffer.removeSubrange(buffer.startIndex...i)
                return Substring(String(decoding: line, as: UTF8.self))
            }
            var chunk = [UInt8](repeating: 0, count: 16384)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 4 << 20 { return nil } // a line this long is not ours
        }
    }
}

/// Writes all of `data`, retrying short writes. False when the other side is gone.
@discardableResult
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard var p = raw.baseAddress else { return true }
        var left = raw.count
        while left > 0 {
            let n = write(fd, p, left)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            left -= n
            p += n
        }
        return true
    }
}

func writeLine(_ fd: Int32, _ obj: JSON) -> Bool {
    guard let line = encode(obj) else { return false }
    return writeAll(fd, (line + "\n").data(using: .utf8)!)
}

/// Copies both ways between two descriptors until either side closes, then closes both and calls `done`.
func join(_ a: Int32, _ b: Int32, done: @escaping () -> Void = {}) {
    let group = DispatchGroup()
    let once = NSLock()
    var closed = false
    func finish() {
        once.lock()
        defer { once.unlock() }
        if closed { return }
        closed = true
        shutdown(a, SHUT_RDWR)
        shutdown(b, SHUT_RDWR)
    }
    for (from, to) in [(a, b), (b, a)] {
        group.enter()
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(from, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                if !writeAll(to, Data(buf[0..<n])) { break }
            }
            // Half-close first so a request / response protocol (HTTP over the Docker socket) still gets its answer.
            shutdown(to, SHUT_WR)
            group.leave()
        }
    }
    group.notify(queue: .global()) {
        finish()
        close(a)
        close(b)
        done()
    }
}

/// A Unix socket listening at `path` (0600, a stale file replaced).
func listenUnix(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { throw Failure("socket(): \(String(cString: strerror(errno)))") }
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    unlink(path)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw Failure("socket path too long: \(path)") }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        for (i, c) in bytes.enumerated() { dst[i] = c }
        dst[bytes.count] = 0
    }
    // umask so the socket is born 0600 (no window where another user could connect)
    let old = umask(0o077)
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    umask(old)
    if r != 0 { close(fd); throw Failure("bind \(path): \(String(cString: strerror(errno)))") }
    chmod(path, 0o600)
    if listen(fd, 128) != 0 { close(fd); throw Failure("listen \(path): \(String(cString: strerror(errno)))") }
    return fd
}

func connectUnix(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw Failure("socket path too long") }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        for (i, c) in bytes.enumerated() { dst[i] = c }
        dst[bytes.count] = 0
    }
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    if r != 0 { close(fd); throw Failure("connect \(path): \(String(cString: strerror(errno)))") }
    return fd
}

/// A TCP listener on loopback (127.0.0.1 or ::1). Nil with errno set when the port is taken.
func listenLoopback(port: UInt16, v6: Bool) -> Int32? {
    let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
    if fd < 0 { return nil }
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
    var r: Int32
    if v6 {
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
        var a = sockaddr_in6()
        a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        a.sin6_family = sa_family_t(AF_INET6)
        a.sin6_port = port.bigEndian
        a.sin6_addr = in6addr_loopback
        r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
    } else {
        var a = sockaddr_in()
        a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian
        a.sin_addr.s_addr = inet_addr("127.0.0.1")
        r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    }
    if r != 0 || listen(fd, 128) != 0 {
        let e = errno
        close(fd)
        errno = e
        return nil
    }
    return fd
}

/// Accepts on `fd` until it is closed, handing each connection to `handle` on its own thread.
func acceptLoop(_ fd: Int32, _ handle: @escaping (Int32) -> Void) {
    Thread.detachNewThread {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            var on: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { handle(c) }
        }
    }
}

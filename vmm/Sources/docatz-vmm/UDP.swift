import Foundation

/// A UDP socket bound on loopback (127.0.0.1 or ::1). Nil when the port is taken.
func bindLoopbackUDP(port: UInt16, v6: Bool) -> Int32? {
    let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_DGRAM, 0)
    if fd < 0 { return nil }
    var on: Int32 = 1
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
    if r != 0 { close(fd); return nil }
    return fd
}

/// Relays one loopback UDP socket to the guest: a vsock stream per client address, each datagram a frame (2-byte
/// big-endian length, then the bytes) both ways. A client's stream ends after 60 s without a datagram, or when the
/// socket is closed (the port is no longer listened on in the guest).
final class UDPRelay {
    private let fd: Int32
    private let port: UInt16
    private let open: () -> Int32?
    private let lock = NSLock()
    private var sessions: [Data: (fd: Int32, used: Date)] = [:]
    private var closed = false

    /// `open` gives a vsock stream to the agent's forward port.
    init(fd: Int32, port: UInt16, open: @escaping () -> Int32?) {
        self.fd = fd
        self.port = port
        self.open = open
        Thread.detachNewThread { [self] in receive() }
        Thread.detachNewThread { [self] in reap() }
    }

    func close() {
        lock.lock()
        closed = true
        let all = sessions
        sessions = [:]
        lock.unlock()
        for (_, s) in all { shutdown(s.fd, SHUT_RDWR) }
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    private func receive() {
        var buf = [UInt8](repeating: 0, count: 65535 + 2)
        while true {
            var from = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = buf.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, raw.baseAddress! + 2, 65535, 0, $0, &len) } }
            }
            if n < 0 {
                if errno == EINTR { continue }
                return
            }
            lock.lock()
            if closed { lock.unlock(); return }
            lock.unlock()
            let key = withUnsafeBytes(of: &from) { Data($0.prefix(Int(len))) }
            guard let g = session(key) else { continue }
            buf[0] = UInt8(n >> 8)
            buf[1] = UInt8(n & 0xff)
            if !writeAll(g, Data(buf[0..<(n + 2)])) { drop(key) }
        }
    }

    private func session(_ key: Data) -> Int32? {
        lock.lock()
        if var s = sessions[key] {
            s.used = Date()
            sessions[key] = s
            lock.unlock()
            return s.fd
        }
        lock.unlock()
        guard let g = open() else { return nil }
        guard writeAll(g, "udp \(port)\n".data(using: .utf8)!) else { Darwin.close(g); return nil }
        lock.lock()
        sessions[key] = (g, Date())
        lock.unlock()
        Thread.detachNewThread { [self] in replies(key, g) }
        return g
    }

    /// The guest's datagrams for one client, sent back to it from this socket.
    private func replies(_ key: Data, _ g: Int32) {
        var head = [UInt8](repeating: 0, count: 2)
        var data = [UInt8](repeating: 0, count: 65535)
        func readFull(_ p: UnsafeMutablePointer<UInt8>, _ count: Int) -> Bool {
            var got = 0
            while got < count {
                let n = read(g, p + got, count - got)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                got += n
            }
            return true
        }
        while readFull(&head, 2) {
            let n = Int(head[0]) << 8 | Int(head[1])
            if n > 0 && !readFull(&data, n) { break }
            lock.lock()
            if var s = sessions[key] { s.used = Date(); sessions[key] = s }
            lock.unlock()
            key.withUnsafeBytes { raw in
                _ = sendto(fd, data, n, 0, raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(key.count))
            }
        }
        drop(key)
        Darwin.close(g)
    }

    private func drop(_ key: Data) {
        lock.lock()
        let s = sessions.removeValue(forKey: key)
        lock.unlock()
        if let s { shutdown(s.fd, SHUT_RDWR) }
    }

    private func reap() {
        while true {
            Thread.sleep(forTimeInterval: 10)
            lock.lock()
            if closed { lock.unlock(); return }
            let old = sessions.filter { Date().timeIntervalSince($0.value.used) > 60 }
            for (k, _) in old { sessions.removeValue(forKey: k) }
            lock.unlock()
            for (_, s) in old { shutdown(s.fd, SHUT_RDWR) }
        }
    }
}

import Foundation

/// What docatz-vmm answers on the Docker socket while the guest sleeps, so a ping, `docker version`, `docker info` or
/// `docker ps` from DoCatz, DevCatz or a terminal does not boot the VM. The answers are dockerd's own, taken just before
/// the guest stopped; anything else wakes the guest and goes through as usual.
final class AsleepAnswers {
    /// Raw HTTP responses by "METHOD /path?query" (the API version prefix taken off).
    private var answers: [String: Data] = [:]

    var isEmpty: Bool { answers.isEmpty }

    /// Reads dockerd's answers through `open` (a new Docker-socket stream each). `docker ps` is answered only when
    /// every container running now has a restart policy that brings it back on wake (what DoCatz's router has):
    /// the list a sleeping engine shows is then the list it will have again.
    static func take(open: () -> Int32?) -> AsleepAnswers {
        let a = AsleepAnswers()
        func get(_ method: String, _ path: String) -> Data? {
            guard let fd = open() else { return nil }
            defer { close(fd) }
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            // HTTP/1.0: dockerd then sends the body whole, ended by the close (an HTTP/1.1 answer over 2 KB came chunked,
            // and could be neither read here nor replayed as is to a client that asked otherwise).
            guard writeAll(fd, "\(method) \(path) HTTP/1.0\r\nHost: docker\r\n\r\n".data(using: .utf8)!) else { return nil }
            var out = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                out.append(contentsOf: buf[0..<n])
                if out.count > 8 << 20 { return nil }
            }
            let status = String(decoding: out.prefix(12), as: UTF8.self)
            guard status.hasPrefix("HTTP/1.1 200") || status.hasPrefix("HTTP/1.0 200") else { return nil }
            return out
        }
        for (m, p) in [("GET", "/_ping"), ("HEAD", "/_ping"), ("GET", "/version"), ("GET", "/info")] {
            if let r = get(m, p) { a.answers["\(m) \(p)"] = r }
        }
        if let running = get("GET", "/containers/json"), let all = get("GET", "/containers/json?all=1") {
            let ids = (try? JSONSerialization.jsonObject(with: body(running))) as? [[String: Any]] ?? []
            let back = ids.allSatisfy { c in
                guard let id = c["Id"] as? String, let r = get("GET", "/containers/\(id)/json"),
                      let o = try? JSONSerialization.jsonObject(with: body(r)) as? [String: Any],
                      let policy = (o["HostConfig"] as? [String: Any])?["RestartPolicy"] as? [String: Any] else { return false }
                return ["always", "unless-stopped"].contains(policy["Name"] as? String ?? "")
            }
            if back {
                a.answers["GET /containers/json"] = running
                a.answers["GET /containers/json?all=1"] = all
            }
        }
        return a
    }

    /// The bytes after the headers.
    private static func body(_ raw: Data) -> Data {
        guard let r = raw.range(of: Data("\r\n\r\n".utf8)) else { return Data() }
        return raw[r.upperBound...]
    }

    /// The saved answer for this request head, or nil (the guest has to wake).
    func answer(_ head: String) -> Data? {
        let line = head.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count == 3 else { return nil }
        let method = String(parts[0])
        var target = String(parts[1])
        // /v1.51/info → /info
        if target.hasPrefix("/v"), let slash = target.dropFirst().firstIndex(of: "/") {
            let v = target[target.index(target.startIndex, offsetBy: 2)..<slash]
            if v.allSatisfy({ $0.isNumber || $0 == "." }) { target = String(target[slash...]) }
        }
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        let query = target.contains("?") ? String(target.split(separator: "?", maxSplits: 1)[1]) : ""
        if path == "/containers/json" && method == "GET" {
            let q = Set(query.split(separator: "&").map(String.init))
            if q.isEmpty || q == ["all=0"] || q == ["all=false"] { return answers["GET /containers/json"] }
            if q == ["all=1"] || q == ["all=true"] { return answers["GET /containers/json?all=1"] }
            return nil
        }
        guard query.isEmpty else { return nil }
        return answers["\(method) \(path)"]
    }
}

/// Reads one request head (up to the blank line) from a client, waiting at most `timeout` seconds. Nil: nothing came,
/// or it is not HTTP; `rest` is every byte read, to pass on unchanged when the guest has to answer.
func readRequestHead(_ fd: Int32, timeout: Int32 = 5) -> (head: String, rest: Data)? {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 16384)
    while data.count < 64 << 10 {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, timeout * 1000) > 0 else { return data.isEmpty ? nil : (String(decoding: data, as: UTF8.self), data) }
        let n = read(fd, &buf, buf.count)
        if n <= 0 { return data.isEmpty ? nil : (String(decoding: data, as: UTF8.self), data) }
        data.append(contentsOf: buf[0..<n])
        if let r = data.range(of: Data("\r\n\r\n".utf8)) {
            return (String(decoding: data[..<r.lowerBound], as: UTF8.self), data)
        }
    }
    return (String(decoding: data, as: UTF8.self), data)
}

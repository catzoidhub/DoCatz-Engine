import Foundation

/// `docatz-vmm run --config <file>` (docs/CONTRACT.md §4).
struct Config: Decodable {
    struct Share: Decodable {
        var path: String
        var readOnly: Bool?
    }

    var kernel: String
    var initrd: String
    var rootfs: String
    var cmdline: String
    var data: String
    var cpus: Int
    var memoryMiB: UInt64
    var rosetta: Bool?
    var shares: [Share]?
    var dockerSocket: String
    var controlSocket: String
    var console: String?
    var forwardPorts: Bool?
    var balloon: Bool?
    var restoreFrom: String?

    static func load(_ path: String) throws -> Config {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let c = try JSONDecoder().decode(Config.self, from: data)
        for (name, p) in [("kernel", c.kernel), ("initrd", c.initrd), ("rootfs", c.rootfs), ("data", c.data)] {
            guard p.hasPrefix("/") else { throw Failure("\(name) must be an absolute path") }
            guard FileManager.default.fileExists(atPath: p) else { throw Failure("\(name) not found: \(p)") }
        }
        for s in c.shares ?? [] {
            var dir: ObjCBool = false
            guard s.path.hasPrefix("/"), FileManager.default.fileExists(atPath: s.path, isDirectory: &dir), dir.boolValue else { throw Failure("share is not a folder: \(s.path)") }
        }
        guard c.cpus >= 1, c.memoryMiB >= 512 else { throw Failure("cpus must be ≥ 1 and memoryMiB ≥ 512") }
        return c
    }

    /// What the guest's init reads from the kernel command line: the shares (tag → path), base64url JSON so paths
    /// with spaces survive.
    func guestCmdline(shareTags: [(tag: String, path: String, readOnly: Bool)], rosetta: Bool) -> String {
        let cfg: JSON = [
            "shares": shareTags.map { ["tag": $0.tag, "path": $0.path, "ro": $0.readOnly] },
            "rosetta": rosetta,
            "tz": TimeZone.current.identifier,
        ]
        let b64 = (encode(cfg) ?? "{}").data(using: .utf8)!.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "\(cmdline) docatz.cfg=\(b64)"
    }
}

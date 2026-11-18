import Foundation
import Virtualization

// docatz-vmm — DoCatz's VM helper on Virtualization.framework (docs/CONTRACT.md).

let VERSION = "0.1.1"
let PROTOCOL = 1

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

func fail(_ message: String, code: Int32 = 1) -> Never {
    Out.event(["event": "error", "message": message])
    exit(code)
}

func arg(_ name: String, _ args: [String]) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func rosettaAvailable() -> Bool {
    #if arch(arm64)
    if #available(macOS 13.0, *) { return VZLinuxRosettaDirectoryShare.availability == .installed }
    #endif
    return false
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "version":
    var arch = "x86_64"
    #if arch(arm64)
    arch = "arm64"
    #endif
    let v = ProcessInfo.processInfo.operatingSystemVersion
    var saveRestore = false
    #if arch(arm64)
    if #available(macOS 14.0, *) { saveRestore = true } // Apple silicon only
    #endif
    print(encode(["version": VERSION, "protocol": PROTOCOL, "arch": arch, "macos": "\(v.majorVersion).\(v.minorVersion)", "rosetta": rosettaAvailable(), "saveRestore": saveRestore])!)

case "disk":
    guard let path = arg("--path", args), let sizeText = arg("--size-gib", args), let gib = UInt64(sizeText), gib >= 1 else {
        print(encode(["error": "usage: docatz-vmm disk --path <data.img> --size-gib <n>"])!)
        exit(2)
    }
    let want = gib << 30
    let fm = FileManager.default
    if !fm.fileExists(atPath: path) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            print(encode(["error": "cannot create \(path)"])!)
            exit(1)
        }
    }
    let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? UInt64) ?? 0
    if want > size {
        // truncate grows the file without writing blocks: it stays sparse on APFS.
        guard truncate(path, off_t(want)) == 0 else {
            print(encode(["error": "cannot grow \(path): \(String(cString: strerror(errno)))"])!)
            exit(1)
        }
    }
    print(encode(["path": path, "sizeGiB": max(want, size) >> 30])!)

case "run":
    guard let path = arg("--config", args) else { fail("usage: docatz-vmm run --config <config.json>", code: 2) }
    let config: Config
    do { config = try Config.load(path) } catch { fail("bad config: \(error)", code: 2) }
    let machine = Machine(config: config)
    machine.start()
    dispatchMain()

case "ctl":
    guard let sock = arg("--socket", args) else { fail("usage: docatz-vmm ctl --socket <vmm.sock> <method> [json]", code: 2) }
    let rest = args.filter { $0 != "ctl" && $0 != "--socket" && $0 != sock }
    guard let method = rest.first else { fail("no method", code: 2) }
    var req: JSON = ["id": 1, "method": method]
    if rest.count > 1, let p = decode(Substring(rest[1])) { req["params"] = p }
    do {
        let fd = try connectUnix(sock)
        _ = writeLine(fd, req)
        let reader = LineReader(fd: fd)
        while let line = reader.next() {
            print(line)
            if let obj = decode(line), obj["id"] != nil, method != "subscribe" { break }
        }
    } catch { fail("\(error)") }

default:
    FileHandle.standardError.write("""
    docatz-vmm \(VERSION) — DoCatz's VM helper (protocol \(PROTOCOL))
      docatz-vmm version
      docatz-vmm disk --path <data.img> --size-gib <n>
      docatz-vmm run --config <config.json>
      docatz-vmm ctl --socket <vmm.sock> <method> [json params]

    """.data(using: .utf8)!)
    exit(args.isEmpty ? 0 : 2)
}

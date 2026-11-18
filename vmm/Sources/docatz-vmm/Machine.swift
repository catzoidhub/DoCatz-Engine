import Foundation
import Virtualization

/// vsock ports the guest agent listens on (agent/main.go).
enum GuestPort {
    static let docker: UInt32 = 2375
    static let forward: UInt32 = 2376
    static let control: UInt32 = 2377
}

/// One VM: built from the config, started, its Docker socket / ports / control socket served, stopped cleanly.
final class Machine: NSObject, VZVirtualMachineDelegate, VZVirtioSocketListenerDelegate {
    let config: Config
    /// Virtualization.framework wants every call on the queue the VM was made on.
    let queue = DispatchQueue(label: "docatz.vmm")
    private var vm: VZVirtualMachine!
    private var socketDevice: VZVirtioSocketDevice?
    private var balloon: VZVirtioTraditionalMemoryBalloonDevice?
    private let started = Date()

    private let lock = NSLock()
    private var state = "starting"
    private var bootMs: Int?
    private var agentVersion: String?
    private var dockerReady = false
    private var targetMiB: UInt64 = 0
    private var stopping = false

    private var agentFd: Int32 = -1
    private var agentSeq = 0
    private var agentWaiting: [Int: (JSON) -> Void] = [:]
    private var subscribers: [Int32] = []
    private var forwards: [UInt16: [Int32]] = [:]
    private var forwardErrors: [UInt16: String] = [:]
    private var signalSources: [DispatchSourceSignal] = []

    init(config: Config) {
        self.config = config
        targetMiB = config.memoryMiB
    }

    // ------------------------------------------------------------------ build and start

    private func build() throws -> VZVirtualMachineConfiguration {
        let c = VZVirtualMachineConfiguration()
        c.cpuCount = min(max(config.cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        let mem = config.memoryMiB << 20
        c.memorySize = min(max(mem, VZVirtualMachineConfiguration.minimumAllowedMemorySize), VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        var tags: [(tag: String, path: String, readOnly: Bool)] = []
        for (i, s) in (config.shares ?? []).enumerated() {
            let tag = "share\(i)"
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            fs.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(fileURLWithPath: s.path), readOnly: s.readOnly ?? false))
            c.directorySharingDevices.append(fs)
            tags.append((tag, s.path, s.readOnly ?? false))
        }
        var rosetta = false
        #if arch(arm64)
        if config.rosetta == true, rosettaAvailable() {
            let fs = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            fs.share = try VZLinuxRosettaDirectoryShare()
            c.directorySharingDevices.append(fs)
            rosetta = true
        }
        #endif

        let boot = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: config.kernel))
        boot.initialRamdiskURL = URL(fileURLWithPath: config.initrd)
        boot.commandLine = config.guestCmdline(shareTags: tags, rosetta: rosetta)
        c.bootLoader = boot
        // One machine identity per data disk: restoring a saved state needs the same identity as the VM that saved it.
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = stableMachineIdentifier()
        c.platform = platform

        // vda: the read-only root; vdb: the data disk. fsync keeps the data disk safe when the Mac loses power.
        let root = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: config.rootfs), readOnly: true, cachingMode: .automatic, synchronizationMode: .none)
        let data = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: config.data), readOnly: false, cachingMode: .automatic, synchronizationMode: .fsync)
        c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: root), VZVirtioBlockDeviceConfiguration(attachment: data)]

        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZNATNetworkDeviceAttachment()
        net.macAddress = stableMac()
        c.networkDevices = [net]

        c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        if config.balloon != false { c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()] }

        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        let logPath = config.console ?? "/dev/null"
        FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        let out = FileHandle(forWritingAtPath: logPath) ?? FileHandle.nullDevice
        console.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: out)
        c.serialPorts = [console]

        try c.validate()
        return c
    }

    /// One MAC per data disk (kept next to it), so the Mac's DHCP gives the VM the same address every boot.
    private func stableMac() -> VZMACAddress {
        let file = (config.data as NSString).deletingLastPathComponent + "/mac"
        if let text = try? String(contentsOfFile: file, encoding: .utf8), let mac = VZMACAddress(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) { return mac }
        let mac = VZMACAddress.randomLocallyAdministered()
        try? mac.string.write(toFile: file, atomically: true, encoding: .utf8)
        return mac
    }

    private func stableMachineIdentifier() -> VZGenericMachineIdentifier {
        let file = (config.data as NSString).deletingLastPathComponent + "/machine-id"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: file)), let id = VZGenericMachineIdentifier(dataRepresentation: data) { return id }
        let id = VZGenericMachineIdentifier()
        FileManager.default.createFile(atPath: file, contents: id.dataRepresentation, attributes: [.posixPermissions: 0o600])
        return id
    }

    func start() {
        Out.event(["event": "state", "state": "starting"])
        let built: VZVirtualMachineConfiguration
        do { built = try build() } catch { fail("the VM could not be set up: \(error.localizedDescription)") }
        do {
            let fd = try listenUnix(config.controlSocket)
            acceptLoop(fd) { [weak self] c in self?.serveControl(c) }
        } catch { fail("control socket: \(error)") }
        do {
            let fd = try listenUnix(config.dockerSocket)
            acceptLoop(fd) { [weak self] c in self?.serveDocker(c) }
        } catch { fail("docker socket: \(error)") }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            s.setEventHandler { [weak self] in self?.stop(timeout: 20) }
            s.resume()
            signalSources.append(s)
        }
        queue.async { [self] in
            vm = VZVirtualMachine(configuration: built, queue: queue)
            vm.delegate = self
            socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice
            balloon = vm.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice
            // The agent calls in on the control port as soon as it runs (polling the guest from here stacked up
            // connects that only failed after the guest's vsock driver loaded: 30 s boots).
            let listener = VZVirtioSocketListener()
            listener.delegate = self
            socketDevice?.setSocketListener(listener, forPort: GuestPort.control)
            socketListener = listener
            let boot = { [self] in
                vm.start { [self] result in
                    if case .failure(let e) = result { fail("the VM did not start: \(e.localizedDescription)") }
                    Out.log("VM started")
                    self.agentDeadline()
                }
            }
            if let from = config.restoreFrom, FileManager.default.fileExists(atPath: from) {
                restore(from, otherwise: boot)
            } else { boot() }
        }
        watchWake()
    }

    private func restore(_ path: String, otherwise boot: @escaping () -> Void) {
        #if arch(arm64)
        guard #available(macOS 14.0, *) else {
            Out.event(["event": "restore-failed", "message": "saving the VM's state needs macOS 14"])
            return boot()
        }
        vm.restoreMachineStateFrom(url: URL(fileURLWithPath: path)) { [self] error in
            try? FileManager.default.removeItem(atPath: path)
            if let error {
                Out.event(["event": "restore-failed", "message": error.localizedDescription])
                return boot()
            }
            vm.resume { [self] r in
                if case .failure(let e) = r { fail("the restored VM did not resume: \(e.localizedDescription)") }
                Out.log("VM restored")
                // The agent's connection was saved with the VM; the clock is set again on its next hello, now.
                Thread.detachNewThread { _ = self.agent(["op": "time", "unix": Date().timeIntervalSince1970]) }
            }
        }
        #else
        Out.event(["event": "restore-failed", "message": "saving the VM's state needs a Mac with Apple silicon"])
        boot()
        #endif
    }

    // ------------------------------------------------------------------ vsock

    /// A connection to a guest port, as a plain descriptor we own (the framework's object is closed at once).
    func vsock(_ port: UInt32, timeout: Double = 5) -> Int32? {
        let sem = DispatchSemaphore(value: 0)
        var out: Int32?
        queue.async { [self] in
            guard let dev = socketDevice else { sem.signal(); return }
            dev.connect(toPort: port) { result in
                if case .success(let conn) = result {
                    let fd = dup(conn.fileDescriptor)
                    conn.close()
                    if fd >= 0 {
                        var on: Int32 = 1
                        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                        out = fd
                    }
                }
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + timeout)
        return out
    }

    // ------------------------------------------------------------------ the agent's control stream

    private var socketListener: VZVirtioSocketListener?

    /// No agent within two minutes: the guest did not come up.
    private func agentDeadline() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { [self] in
            lock.lock()
            let none = agentVersion == nil && !stopping
            lock.unlock()
            if none { fail("the guest agent did not answer within two minutes — see the console log") }
        }
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection, from socketDevice: VZVirtioSocketDevice) -> Bool {
        let fd = dup(connection.fileDescriptor)
        connection.close()
        guard fd >= 0 else { return false }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        lock.lock()
        let old = agentFd
        lock.unlock()
        if old >= 0 { shutdown(old, SHUT_RDWR) }
        Out.log("guest agent connected")
        Thread.detachNewThread { self.agentStream(fd) }
        return true
    }

    private func agentStream(_ fd: Int32) {
        lock.lock()
        agentFd = fd
        lock.unlock()
        let reader = LineReader(fd: fd)
        while let line = reader.next() {
            guard let msg = decode(line) else { continue }
            if let id = msg["id"] as? Int {
                lock.lock()
                let done = agentWaiting.removeValue(forKey: id)
                lock.unlock()
                done?(msg)
                continue
            }
            handleAgentEvent(msg)
        }
        lock.lock()
        if agentFd == fd { agentFd = -1 }
        let waiting = agentWaiting
        agentWaiting = [:]
        lock.unlock()
        for (_, done) in waiting { done(["ok": false, "error": "the guest agent went away"]) }
        close(fd)
        if !stopping { Out.log("guest agent connection closed") }
    }

    private func handleAgentEvent(_ msg: JSON) {
        switch msg["event"] as? String {
        case "hello":
            Out.log("guest agent \(msg["agent"] as? String ?? "?") said hello")
            lock.lock()
            agentVersion = msg["agent"] as? String
            lock.unlock()
            // Never wait for an answer on this thread: it is the one that reads the answer.
            DispatchQueue.global().async { _ = self.agent(["op": "time", "unix": Date().timeIntervalSince1970]) }
        case "docker":
            let ready = msg["ready"] as? Bool ?? false
            lock.lock()
            let first = ready && !dockerReady && state == "starting"
            dockerReady = ready
            if first {
                state = "running"
                bootMs = Int(Date().timeIntervalSince(started) * 1000)
            }
            let ms = bootMs
            lock.unlock()
            Out.log("docker ready: \(ready)")
            if first { emit(["event": "state", "state": "running", "bootMs": ms ?? 0]) }
        case "ports":
            if config.forwardPorts != false { updateForwards(msg["ports"] as? [JSON] ?? []) }
        case "log":
            if let text = msg["text"] as? String { Out.log("guest: \(text)") }
        default:
            break
        }
    }

    /// Sends one op to the agent and waits for its answer (nil: no agent / timed out).
    @discardableResult
    func agent(_ op: JSON, timeout: Double = 30) -> JSON? {
        lock.lock()
        let fd = agentFd
        agentSeq += 1
        let id = agentSeq
        let sem = DispatchSemaphore(value: 0)
        var answer: JSON?
        if fd >= 0 { agentWaiting[id] = { answer = $0; sem.signal() } }
        lock.unlock()
        guard fd >= 0 else { return nil }
        defer { answer?.removeValue(forKey: "id") }
        var msg = op
        msg["id"] = id
        guard writeLine(fd, msg) else { return nil }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock()
            agentWaiting.removeValue(forKey: id)
            lock.unlock()
            return nil
        }
        return answer
    }

    // ------------------------------------------------------------------ Docker socket and ports

    private func serveDocker(_ c: Int32) {
        // Before dockerd is ready a connection waits (up to 60 s) rather than failing.
        for _ in 0..<600 {
            lock.lock()
            let ready = dockerReady || state == "running"
            let gone = stopping
            lock.unlock()
            if ready || gone { break }
            usleep(100_000)
        }
        guard let g = vsock(GuestPort.docker) else { close(c); return }
        join(c, g)
    }

    private func updateForwards(_ list: [JSON]) {
        let want = Set(list.compactMap { ($0["proto"] as? String ?? "tcp") == "tcp" ? ($0["port"] as? Int).flatMap { UInt16(exactly: $0) } : nil })
        lock.lock()
        let have = Set(forwards.keys)
        lock.unlock()
        for port in have.subtracting(want) {
            lock.lock()
            let fds = forwards.removeValue(forKey: port) ?? []
            forwardErrors.removeValue(forKey: port)
            lock.unlock()
            for fd in fds { shutdown(fd, SHUT_RDWR); close(fd) }
        }
        for port in want.subtracting(have) {
            var fds: [Int32] = []
            for v6 in [false, true] {
                if let fd = listenLoopback(port: port, v6: v6) {
                    fds.append(fd)
                    acceptLoop(fd) { [weak self] c in self?.serveForward(c, port: port) }
                }
            }
            lock.lock()
            forwards[port] = fds
            if fds.isEmpty { forwardErrors[port] = "in use" } else { forwardErrors.removeValue(forKey: port) }
            lock.unlock()
        }
        if want != have { emit(["event": "ports", "ports": portList()]) }
    }

    private func portList() -> [JSON] {
        lock.lock()
        defer { lock.unlock() }
        return forwards.keys.sorted().map { p in
            var o: JSON = ["proto": "tcp", "port": Int(p)]
            if let e = forwardErrors[p] { o["error"] = e }
            return o
        }
    }

    private func serveForward(_ c: Int32, port: UInt16) {
        guard let g = vsock(GuestPort.forward) else { close(c); return }
        guard writeAll(g, "tcp \(port)\n".data(using: .utf8)!) else { close(c); close(g); return }
        join(c, g)
    }

    // ------------------------------------------------------------------ DoCatz's control socket

    private func emit(_ event: JSON) {
        Out.event(event)
        lock.lock()
        let subs = subscribers
        lock.unlock()
        for fd in subs where !writeLine(fd, event) {
            lock.lock()
            subscribers.removeAll { $0 == fd }
            lock.unlock()
        }
    }

    private func status() -> JSON {
        lock.lock()
        defer { lock.unlock() }
        var guest: JSON = ["docker": dockerReady]
        if let a = agentVersion { guest["agent"] = a }
        if let b = bootMs { guest["bootMs"] = b }
        return [
            "state": state, "version": VERSION, "protocol": PROTOCOL, "pid": Int(getpid()), "guest": guest,
            "memory": ["configuredMiB": config.memoryMiB, "targetMiB": targetMiB],
            "ports": forwards.keys.sorted().map { ["proto": "tcp", "port": Int($0)] },
        ]
    }

    private func serveControl(_ fd: Int32) {
        let reader = LineReader(fd: fd)
        while let line = reader.next() {
            guard let req = decode(line) else { _ = writeLine(fd, ["error": "not JSON"]); continue }
            let id = req["id"] ?? NSNull()
            let params = req["params"] as? JSON ?? [:]
            func answer(_ result: Any) { _ = writeLine(fd, ["id": id, "result": result]) }
            func refuse(_ e: String) { _ = writeLine(fd, ["id": id, "error": e]) }
            switch req["method"] as? String ?? "" {
            case "status":
                answer(status())
            case "ports":
                answer(portList())
            case "stop":
                answer(["stopping": true])
                stop(timeout: params["timeoutSec"] as? Double ?? 20)
            case "kill":
                answer(["killed": true])
                kill()
            case "subscribe":
                lock.lock()
                subscribers.append(fd)
                lock.unlock()
                answer(["subscribed": true])
            case "fsevents":
                let files = (params["files"] as? [JSON] ?? []).prefix(1000).compactMap { f -> JSON? in
                    guard let p = f["path"] as? String, let t = f["mtime"] as? String else { return nil }
                    return ["path": p, "mtime": t]
                }
                if let r = agent(["op": "fsevents", "files": files]) { answer(r) } else { refuse("the guest agent is not connected") }
            case "sync-time":
                if let r = agent(["op": "time", "unix": Date().timeIntervalSince1970]) { answer(r) } else { refuse("the guest agent is not connected") }
            case "trim":
                if let r = agent(["op": "trim"], timeout: 300) { answer(r) } else { refuse("the guest agent is not connected") }
            case "balloon":
                let mib = UInt64(params["targetMiB"] as? Int ?? 0)
                let target = mib == 0 ? config.memoryMiB : min(max(mib, 512), config.memoryMiB)
                queue.sync {
                    balloon?.targetVirtualMachineMemorySize = target << 20
                }
                lock.lock()
                targetMiB = target
                lock.unlock()
                answer(["targetMiB": target])
            case "save":
                guard let path = params["path"] as? String, path.hasPrefix("/") else { refuse("save needs an absolute path"); break }
                save(path) { err in err == nil ? answer(["saved": path]) : refuse(err!) }
            default:
                refuse("unknown method")
            }
        }
        lock.lock()
        subscribers.removeAll { $0 == fd }
        lock.unlock()
        close(fd)
    }

    // ------------------------------------------------------------------ stop, save, wake

    func stop(timeout: Double) {
        lock.lock()
        if stopping { lock.unlock(); return }
        stopping = true
        state = "stopping"
        lock.unlock()
        emit(["event": "state", "state": "stopping"])
        Thread.detachNewThread { [self] in
            // The agent stops dockerd (its containers stop), syncs and powers off; the framework then says guestDidStop.
            if agent(["op": "shutdown"], timeout: timeout) == nil {
                queue.async { [self] in
                    if vm.canRequestStop { try? vm.requestStop() }
                }
            }
            Thread.sleep(forTimeInterval: timeout)
            kill()
        }
    }

    func kill() {
        queue.async { [self] in
            guard vm != nil, vm.canStop else { return finish(code: 0) }
            vm.stop { [self] _ in finish(code: 0) }
        }
    }

    private func save(_ path: String, done: @escaping (String?) -> Void) {
        #if arch(arm64)
        guard #available(macOS 14.0, *) else { return done("saving the VM's state needs macOS 14") }
        _ = agent(["op": "sync"], timeout: 10)
        queue.async { [self] in
            vm.pause { [self] r in
                if case .failure(let e) = r { return done(e.localizedDescription) }
                vm.saveMachineStateTo(url: URL(fileURLWithPath: path)) { [self] error in
                    if let error {
                        vm.resume { _ in }
                        return done(error.localizedDescription)
                    }
                    done(nil)
                    finish(code: 0)
                }
            }
        }
        #else
        done("saving the VM's state needs a Mac with Apple silicon")
        #endif
    }

    private func finish(code: Int32) {
        lock.lock()
        state = "stopped"
        lock.unlock()
        emit(["event": "state", "state": "stopped"])
        unlink(config.dockerSocket)
        unlink(config.controlSocket)
        exit(code)
    }

    /// After the Mac sleeps the guest's clock is behind: a jump in wall time between two ticks sets it again.
    private func watchWake() {
        var last = Date()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            let now = Date()
            if now.timeIntervalSince(last) > 30 { _ = self?.agent(["op": "time", "unix": now.timeIntervalSince1970]) }
            last = now
        }
        timer.resume()
        wakeTimer = timer
    }
    private var wakeTimer: DispatchSourceTimer?

    // ------------------------------------------------------------------ VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        Out.log("guest stopped")
        finish(code: 0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        lock.lock()
        state = "error"
        lock.unlock()
        emit(["event": "error", "message": error.localizedDescription])
        unlink(config.dockerSocket)
        unlink(config.controlSocket)
        exit(1)
    }
}

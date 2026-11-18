// docatz-agent — PID 1 of the DoCatz Lite guest (docs/CONTRACT.md).
//
// guest/rootfs/sbin/docatz-init prepares the system (mounts, network, data disk) and then execs this program, which:
//   - starts dockerd and keeps it running;
//   - joins vsock port 2375 to /var/run/docker.sock (the Mac's Docker socket);
//   - on vsock port 2376 reads "tcp <port>\n" and joins the stream to that port in the guest (published ports);
//   - answers DNS for host.docker.internal and joins connections to it to the Mac's loopback (hostnet.go);
//   - calls docatz-vmm on the host's vsock port 2377 (and again whenever that connection drops) and talks JSON lines
//     on it: events (hello, docker ready, the listening ports) out, operations (time, shutdown, fsevents, trim, sync) in;
//   - reaps orphaned processes, as PID 1 must.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

var version = "0.1.6"

const (
	portDocker  = 2375
	portForward = 2376
	portControl = 2377
	dockerSock  = "/var/run/docker.sock"
)

func logf(format string, a ...any) {
	up, _ := os.ReadFile("/proc/uptime")
	t, _, _ := strings.Cut(string(up), " ")
	fmt.Fprintf(os.Stdout, "docatz-agent ["+t+"] "+format+"\n", a...)
}

func main() {
	if os.Getpid() == 1 {
		go reap()
	}
	logf("version %s", version)
	d := &docker{}
	go d.run()

	c := &control{docker: d}
	go serve(portDocker, func(conn net.Conn) { joinUnix(conn, dockerSock) })
	go serve(portForward, forward)
	go serveHostLoop()
	go serveDNS()
	go c.dialHost()
	go c.watchPorts()
	if selftestWanted() {
		go selftest(d)
	}

	// Outside PID 1 (a test run), SIGTERM stops dockerd first.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	d.stop(15 * time.Second)
	if os.Getpid() == 1 {
		powerOff()
	}
}

// ---------------------------------------------------------------- PID 1

// childExits lets the code that started a child (dockerd) get its exit status from the reaper.
var (
	childMu    sync.Mutex
	childExits = map[int]chan syscall.WaitStatus{}
)

func watchChild(pid int) chan syscall.WaitStatus {
	ch := make(chan syscall.WaitStatus, 1)
	childMu.Lock()
	childExits[pid] = ch
	childMu.Unlock()
	return ch
}

func reap() {
	sig := make(chan os.Signal, 16)
	signal.Notify(sig, syscall.SIGCHLD)
	for range sig {
		for {
			var ws syscall.WaitStatus
			pid, err := syscall.Wait4(-1, &ws, syscall.WNOHANG, nil)
			if pid <= 0 || err != nil {
				break
			}
			childMu.Lock()
			ch := childExits[pid]
			delete(childExits, pid)
			childMu.Unlock()
			if ch != nil {
				ch <- ws
			}
		}
	}
}

func powerOff() {
	syscall.Sync()
	for _, m := range []string{"/var/lib/docker", "/var/lib/containerd", "/mnt/data"} {
		_ = unix.Unmount(m, 0)
	}
	syscall.Sync()
	_ = unix.Reboot(unix.LINUX_REBOOT_CMD_POWER_OFF)
}

// ---------------------------------------------------------------- dockerd

type docker struct {
	mu      sync.Mutex
	cmd     *exec.Cmd
	exit    chan syscall.WaitStatus
	done    chan struct{} // closed when the current dockerd has exited
	ready   bool
	stopped bool
	onReady func(bool)
}

func (d *docker) run() {
	backoff := time.Second
	for {
		d.mu.Lock()
		if d.stopped {
			d.mu.Unlock()
			return
		}
		cmd := exec.Command("/usr/bin/dockerd", "--host", "unix://"+dockerSock)
		cmd.Stdout = os.Stdout
		cmd.Stderr = os.Stdout
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		d.mu.Unlock()
		if err := startChild(cmd); err != nil {
			logf("dockerd did not start: %v", err)
			time.Sleep(backoff)
			continue
		}
		d.mu.Lock()
		d.cmd = cmd
		d.exit = waitChild(cmd)
		d.done = make(chan struct{})
		exit, done := d.exit, d.done
		d.mu.Unlock()
		started := time.Now()
		go d.waitReady(done)
		ws := <-exit
		close(done)
		d.setReady(false)
		d.mu.Lock()
		stopped := d.stopped
		d.mu.Unlock()
		if stopped {
			return
		}
		logf("dockerd exited (%v); starting it again", ws)
		if time.Since(started) > time.Minute {
			backoff = time.Second
		} else if backoff < 30*time.Second {
			backoff *= 2
		}
		time.Sleep(backoff)
	}
}

// startChild starts cmd; as PID 1 its exit status goes through the reaper.
func startChild(cmd *exec.Cmd) error {
	if os.Getpid() != 1 {
		return cmd.Start()
	}
	// The reaper must know the pid before it can exit: hold the map while starting.
	childMu.Lock()
	defer childMu.Unlock()
	if err := cmd.Start(); err != nil {
		return err
	}
	ch := make(chan syscall.WaitStatus, 1)
	childExits[cmd.Process.Pid] = ch
	return nil
}

func waitChild(cmd *exec.Cmd) chan syscall.WaitStatus {
	if os.Getpid() == 1 {
		childMu.Lock()
		ch := childExits[cmd.Process.Pid]
		childMu.Unlock()
		if ch != nil {
			return ch
		}
		return watchChild(cmd.Process.Pid)
	}
	ch := make(chan syscall.WaitStatus, 1)
	go func() {
		_ = cmd.Wait()
		if cmd.ProcessState != nil {
			ch <- cmd.ProcessState.Sys().(syscall.WaitStatus)
		} else {
			ch <- 0
		}
	}()
	return ch
}

func (d *docker) waitReady(done chan struct{}) {
	client := http.Client{Timeout: 2 * time.Second, Transport: &http.Transport{DialContext: nil, Dial: func(_, _ string) (net.Conn, error) { return net.Dial("unix", dockerSock) }}}
	for i := 0; i < 1200; i++ {
		select {
		case <-done:
			return
		default:
		}
		if r, err := client.Get("http://docker/_ping"); err == nil {
			r.Body.Close()
			if r.StatusCode == 200 {
				d.setReady(true)
				return
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func (d *docker) setReady(ready bool) {
	d.mu.Lock()
	changed := d.ready != ready
	d.ready = ready
	cb := d.onReady
	d.mu.Unlock()
	if changed {
		logf("dockerd ready: %v", ready)
		if cb != nil {
			cb(ready)
		}
	}
}

func (d *docker) isReady() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.ready
}

// stop ends dockerd (it stops its containers first) and waits up to timeout.
func (d *docker) stop(timeout time.Duration) {
	d.mu.Lock()
	d.stopped = true
	cmd, done := d.cmd, d.done
	d.mu.Unlock()
	if cmd == nil || cmd.Process == nil || done == nil {
		return
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(timeout):
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
}

// ---------------------------------------------------------------- vsock

func serve(port uint32, handle func(net.Conn)) {
	for {
		l, err := listenVsock(port)
		if err != nil {
			logf("vsock %d: %v", port, err)
			time.Sleep(time.Second)
			continue
		}
		for {
			c, err := l.Accept()
			if err != nil {
				logf("vsock %d accept: %v", port, err)
				break
			}
			go handle(c)
		}
		l.Close()
	}
}

func joinUnix(c net.Conn, path string) {
	defer c.Close()
	var u net.Conn
	var err error
	// dockerd may be (re)starting: wait for its socket a little.
	for i := 0; i < 100; i++ {
		if u, err = net.Dial("unix", path); err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		return
	}
	pipe(c, u)
}

func forward(c net.Conn) {
	defer c.Close()
	r := bufio.NewReader(c)
	line, err := r.ReadString('\n')
	if err != nil {
		return
	}
	f := strings.Fields(line)
	if len(f) != 2 || (f[0] != "tcp" && f[0] != "udp") {
		return
	}
	port, err := strconv.Atoi(f[1])
	if err != nil || port < 1 || port > 65535 {
		return
	}
	if f[0] == "udp" {
		forwardUDP(c, r, f[1])
		return
	}
	// 127.0.0.1 first (it also reaches 0.0.0.0 listeners), then ::1 for an IPv6-only listener.
	t, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", f[1]), 5*time.Second)
	if err != nil {
		if t, err = net.DialTimeout("tcp", net.JoinHostPort("::1", f[1]), 5*time.Second); err != nil {
			return
		}
	}
	// Bytes the reader already took past the header belong to the stream.
	if n := r.Buffered(); n > 0 {
		b, _ := r.Peek(n)
		if _, err := t.Write(b); err != nil {
			t.Close()
			return
		}
	}
	pipe(c, t)
}

// forwardUDP: one stream per client on the Mac. Each datagram is a frame (2-byte big-endian length, then the bytes),
// both ways; the stream ends when the Mac closes it or after 90 s without a datagram.
func forwardUDP(c net.Conn, r *bufio.Reader, port string) {
	u, err := net.Dial("udp", net.JoinHostPort("127.0.0.1", port))
	if err != nil {
		return
	}
	defer u.Close()
	go func() {
		buf := make([]byte, 65535+2)
		for {
			_ = u.SetReadDeadline(time.Now().Add(90 * time.Second))
			n, err := u.Read(buf[2:])
			if err != nil {
				c.Close()
				return
			}
			buf[0], buf[1] = byte(n>>8), byte(n)
			if _, err := c.Write(buf[:n+2]); err != nil {
				return
			}
		}
	}()
	head := make([]byte, 2)
	data := make([]byte, 65535)
	for {
		if _, err := io.ReadFull(r, head); err != nil {
			return
		}
		n := int(head[0])<<8 | int(head[1])
		if _, err := io.ReadFull(r, data[:n]); err != nil {
			return
		}
		// A refused datagram (nothing listening yet) is not the stream's end.
		_, _ = u.Write(data[:n])
	}
}

// pipe copies both ways; each side's end half-closes the other, so request / response protocols finish.
func pipe(a, b net.Conn) {
	defer b.Close()
	done := make(chan struct{}, 2)
	cp := func(dst, src net.Conn) {
		_, _ = io.Copy(dst, src)
		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		} else {
			_ = dst.Close()
		}
		done <- struct{}{}
	}
	go cp(a, b)
	go cp(b, a)
	<-done
	<-done
}

// ---------------------------------------------------------------- control stream

type control struct {
	docker *docker
	mu     sync.Mutex
	conns  map[net.Conn]*json.Encoder
	ports  []int
}

func (c *control) send(msg map[string]any) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for conn, enc := range c.conns {
		if err := enc.Encode(msg); err != nil {
			conn.Close()
			delete(c.conns, conn)
		}
	}
}

// dialHost keeps one control connection to docatz-vmm (the host, CID 2).
func (c *control) dialHost() {
	for {
		conn, err := dialVsock(unix.VMADDR_CID_HOST, portControl)
		if err != nil {
			time.Sleep(50 * time.Millisecond)
			continue
		}
		logf("connected to docatz-vmm")
		c.handle(conn)
		logf("docatz-vmm connection closed")
		time.Sleep(200 * time.Millisecond)
	}
}

func (c *control) handle(conn net.Conn) {
	defer conn.Close()
	enc := json.NewEncoder(conn)
	c.mu.Lock()
	if c.conns == nil {
		c.conns = map[net.Conn]*json.Encoder{}
	}
	c.conns[conn] = enc
	ports := c.ports
	c.mu.Unlock()
	c.docker.mu.Lock()
	c.docker.onReady = func(ready bool) { c.send(map[string]any{"event": "docker", "ready": ready}) }
	c.docker.mu.Unlock()
	c.send(map[string]any{"event": "hello", "agent": version})
	c.send(map[string]any{"event": "docker", "ready": c.docker.isReady()})
	c.send(map[string]any{"event": "ports", "ports": portList(ports)})

	dec := json.NewDecoder(conn)
	for {
		var req map[string]any
		if err := dec.Decode(&req); err != nil {
			break
		}
		go func() {
			res := c.op(req)
			res["id"] = req["id"]
			c.mu.Lock()
			if e := c.conns[conn]; e != nil {
				_ = e.Encode(res)
			}
			c.mu.Unlock()
		}()
	}
	c.mu.Lock()
	delete(c.conns, conn)
	c.mu.Unlock()
}

func fail(err error) map[string]any { return map[string]any{"ok": false, "error": err.Error()} }

func (c *control) op(req map[string]any) map[string]any {
	switch req["op"] {
	case "time":
		unixTime, _ := req["unix"].(float64)
		if unixTime < 1e9 {
			return fail(fmt.Errorf("bad time"))
		}
		sec := int64(unixTime)
		tv := unix.NsecToTimeval(sec*1e9 + int64((unixTime-float64(sec))*1e9))
		if err := unix.Settimeofday(&tv); err != nil {
			return fail(err)
		}
		return map[string]any{"ok": true}
	case "sync":
		syscall.Sync()
		return map[string]any{"ok": true}
	case "trim":
		out, err := exec.Command("/sbin/fstrim", "-v", "/mnt/data").CombinedOutput()
		// As PID 1 the reaper may collect the child before Wait does (ECHILD): the output is still all there.
		if err != nil && !strings.Contains(err.Error(), "no child processes") {
			return fail(fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out))))
		}
		return map[string]any{"ok": true, "output": strings.TrimSpace(string(out))}
	case "fsevents":
		files, _ := req["files"].([]any)
		n := 0
		for _, f := range files {
			m, _ := f.(map[string]any)
			p, _ := m["path"].(string)
			t, _ := m["mtime"].(string)
			if p == "" || !strings.HasPrefix(p, "/") {
				continue
			}
			ts, err := parseStamp(t)
			if err != nil {
				continue
			}
			// Setting the file's own time again: an inotify event here, no change to the file (as Standard's touch -c -m).
			if err := unix.UtimesNanoAt(unix.AT_FDCWD, p, []unix.Timespec{{Sec: 0, Nsec: unix.UTIME_OMIT}, ts}, unix.AT_SYMLINK_NOFOLLOW); err == nil {
				n++
			}
		}
		return map[string]any{"ok": true, "touched": n}
	case "shutdown":
		go func() {
			c.docker.stop(15 * time.Second)
			if os.Getpid() == 1 {
				powerOff()
			}
			os.Exit(0)
		}()
		return map[string]any{"ok": true}
	}
	return fail(fmt.Errorf("unknown op %v", req["op"]))
}

func parseStamp(s string) (unix.Timespec, error) {
	sec, frac, _ := strings.Cut(s, ".")
	secs, err := strconv.ParseInt(sec, 10, 64)
	if err != nil {
		return unix.Timespec{}, err
	}
	var nsec int64
	if frac != "" {
		frac = (frac + "000000000")[:9]
		if nsec, err = strconv.ParseInt(frac, 10, 64); err != nil {
			return unix.Timespec{}, err
		}
	}
	return unix.Timespec{Sec: secs, Nsec: nsec}, nil
}

// ---------------------------------------------------------------- listening ports

// A UDP port is kept in the same sorted list as the TCP ones, above them (port + udpBase).
const udpBase = 1 << 16

func portList(ports []int) []map[string]any {
	out := make([]map[string]any, 0, len(ports))
	for _, p := range ports {
		if p >= udpBase {
			out = append(out, map[string]any{"proto": "udp", "port": p - udpBase})
		} else {
			out = append(out, map[string]any{"proto": "tcp", "port": p})
		}
	}
	return out
}

// watchPorts reads the guest's listening TCP sockets once a second and sends the list when it changes: those bound to
// every address (0.0.0.0 / ::, what `docker run -p` makes) and those on the VM's loopback (127.0.0.1 / ::1), as Lima
// forwards them — DoCatz's router (domains, DBCatz's database ports) runs on the VM's host network on 127.0.0.1.
func (c *control) watchPorts() {
	for {
		ports := listening()
		c.mu.Lock()
		changed := !equal(ports, c.ports)
		if changed {
			c.ports = ports
		}
		c.mu.Unlock()
		if changed {
			c.send(map[string]any{"event": "ports", "ports": portList(ports)})
		}
		time.Sleep(time.Second)
	}
}

func listening() []int {
	seen := map[int]bool{}
	for _, f := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(b), "\n")[1:] {
			fields := strings.Fields(line)
			if len(fields) < 4 || fields[3] != "0A" { // 0A = LISTEN
				continue
			}
			addr, portHex, ok := strings.Cut(fields[1], ":")
			if !ok || !forwardable(addr) {
				continue
			}
			if p, err := strconv.ParseInt(portHex, 16, 32); err == nil && p > 0 {
				seen[int(p)] = true
			}
		}
	}
	// UDP: sockets bound (not connected) to any address or loopback, below the ephemeral range — what `-p …/udp` and a
	// host-network server make; a client's own socket has an ephemeral port. 68 is the guest's DHCP client.
	low := 32768
	if b, err := os.ReadFile("/proc/sys/net/ipv4/ip_local_port_range"); err == nil {
		if f := strings.Fields(string(b)); len(f) == 2 {
			if v, err := strconv.Atoi(f[0]); err == nil {
				low = v
			}
		}
	}
	for _, f := range []string{"/proc/net/udp", "/proc/net/udp6"} {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(string(b), "\n")[1:] {
			fields := strings.Fields(line)
			if len(fields) < 4 {
				continue
			}
			addr, portHex, ok := strings.Cut(fields[1], ":")
			rem, remPort, ok2 := strings.Cut(fields[2], ":")
			if !ok || !ok2 || !forwardable(addr) || strings.Trim(rem, "0") != "" || strings.Trim(remPort, "0") != "" {
				continue
			}
			if p, err := strconv.ParseInt(portHex, 16, 32); err == nil && p > 0 && int(p) < low && p != 68 {
				seen[udpBase+int(p)] = true
			}
		}
	}
	out := make([]int, 0, len(seen))
	for p := 1; p < 2*udpBase && len(out) < len(seen); p++ {
		if seen[p] {
			out = append(out, p)
		}
	}
	return out
}

// forwardable: any address, or loopback (127.0.0.1 is 0100007F, ::1 is 0…01000000 in /proc/net/tcp*'s byte order).
func forwardable(addr string) bool {
	return strings.Trim(addr, "0") == "" || addr == "0100007F" || addr == "00000000000000000000000001000000"
}

func equal(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

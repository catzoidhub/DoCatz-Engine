package main

// The Mac as seen from containers (docs/CONTRACT.md, "The Mac from inside").
//
//   - hostIP (198.19.200.2) is the Mac's loopback: docatz-init puts it on the guest's lo and DNATs every TCP connection
//     to it onto the agent's listener at hostIP:portHostLoop; the agent reads the original port (SO_ORIGINAL_DST) and
//     calls docatz-vmm on the host's vsock port 2378 with "tcp <port>\n", and docatz-vmm joins the stream to the Mac's
//     127.0.0.1:<port> (then ::1). So a container reaches a database that listens only on the Mac's 127.0.0.1.
//   - dnsIP (198.19.200.3):53 is dockerd's DNS (daemon.json "dns"): it answers host.docker.internal, its aliases and
//     every <name>.localhost with hostIP and passes every other question to the guest's own nameservers (/etc/resolv.conf, the Mac's NAT).
//     Docker's embedded DNS (127.0.0.11, user-defined networks) uses it as its upstream, so every network gets the name.

import (
	"encoding/binary"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
	"unsafe"

	"golang.org/x/sys/unix"
)

const (
	hostIP       = "198.19.200.2"
	dnsIP        = "198.19.200.3"
	portHostLoop = 2378
)

// hostNames: the names that mean the Mac, as Docker Desktop and Lima use them.
var hostNames = map[string]bool{
	"host.docker.internal":         true,
	"gateway.docker.internal":      true,
	"host.lima.internal":           true,
	"host.docatz.internal":         true,
	"docker.for.mac.host.internal": true,
	"docker.for.mac.localhost":     true,
}

// ---------------------------------------------------------------- the Mac's loopback

func serveHostLoop() {
	var l net.Listener
	var err error
	for i := 0; i < 50; i++ { // docatz-init adds the address; a moment's wait covers a slow lo
		if l, err = net.Listen("tcp4", net.JoinHostPort(hostIP, strconv.Itoa(portHostLoop))); err == nil {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		logf("host loopback: %v", err)
		return
	}
	for {
		c, err := l.Accept()
		if err != nil {
			time.Sleep(100 * time.Millisecond)
			continue
		}
		go hostLoop(c.(*net.TCPConn))
	}
}

func hostLoop(c *net.TCPConn) {
	port, err := originalPort(c)
	if err != nil || port == portHostLoop {
		c.Close()
		return
	}
	h, err := dialVsock(unix.VMADDR_CID_HOST, portHostLoop)
	if err == nil {
		_, err = io.WriteString(h, "tcp "+strconv.Itoa(port)+"\n")
		if err == nil {
			// docatz-vmm answers one byte: 1 when the Mac's port took the connection, 0 when nothing listens there.
			b := make([]byte, 1)
			_ = h.SetReadDeadline(time.Now().Add(10 * time.Second))
			if _, err = io.ReadFull(h, b); err == nil && b[0] != 1 {
				err = io.EOF
			}
			_ = h.SetReadDeadline(time.Time{})
		}
	}
	if err != nil {
		if h != nil {
			h.Close()
		}
		_ = c.SetLinger(0) // a reset, as a closed port gives
		c.Close()
		return
	}
	pipe(c, h)
}

// originalPort: the port the container asked for, before the DNAT onto our listener.
func originalPort(c *net.TCPConn) (int, error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return 0, err
	}
	var port int
	var serr error
	err = raw.Control(func(fd uintptr) {
		var sa unix.RawSockaddrInet4
		size := uint32(unsafe.Sizeof(sa))
		const soOriginalDst = 80
		_, _, e := unix.Syscall6(unix.SYS_GETSOCKOPT, fd, unix.SOL_IP, soOriginalDst,
			uintptr(unsafe.Pointer(&sa)), uintptr(unsafe.Pointer(&size)), 0)
		if e != 0 {
			serr = e
			return
		}
		p := (*[2]byte)(unsafe.Pointer(&sa.Port))
		port = int(binary.BigEndian.Uint16(p[:]))
	})
	if err == nil {
		err = serr
	}
	return port, err
}

// ---------------------------------------------------------------- DNS

func serveDNS() {
	go func() {
		var pc net.PacketConn
		var err error
		for i := 0; i < 50; i++ {
			if pc, err = net.ListenPacket("udp4", net.JoinHostPort(dnsIP, "53")); err == nil {
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
		if err != nil {
			logf("dns: %v", err)
			return
		}
		buf := make([]byte, 65535)
		for {
			n, from, err := pc.ReadFrom(buf)
			if err != nil {
				continue
			}
			q := append([]byte(nil), buf[:n]...)
			go func() {
				if a := dnsAnswer(q, "udp"); a != nil {
					_, _ = pc.WriteTo(a, from)
				}
			}()
		}
	}()
	l, err := net.Listen("tcp4", net.JoinHostPort(dnsIP, "53"))
	if err != nil {
		logf("dns tcp: %v", err)
		return
	}
	for {
		c, err := l.Accept()
		if err != nil {
			continue
		}
		go func() {
			defer c.Close()
			for {
				_ = c.SetDeadline(time.Now().Add(30 * time.Second))
				var n uint16
				if binary.Read(c, binary.BigEndian, &n) != nil {
					return
				}
				q := make([]byte, n)
				if _, err := io.ReadFull(c, q); err != nil {
					return
				}
				a := dnsAnswer(q, "tcp")
				if a == nil {
					return
				}
				out := make([]byte, 2+len(a))
				binary.BigEndian.PutUint16(out, uint16(len(a)))
				copy(out[2:], a)
				if _, err := c.Write(out); err != nil {
					return
				}
			}
		}()
	}
}

// dnsAnswer: our own answer for the Mac's names, the upstream's for everything else (nil: no answer at all).
func dnsAnswer(q []byte, network string) []byte {
	if a := localAnswer(q); a != nil {
		return a
	}
	for _, ns := range upstreams() {
		if a := ask(ns, q, network); a != nil {
			return a
		}
	}
	return servfail(q)
}

// localAddrs: the addresses we answer for a name ourselves (A, AAAA), or ok=false to ask upstream.
//   - the Mac's names (hostNames) and any <name>.localhost: A hostIP, no AAAA (so a client never tries ::1, which in a
//     container is the container itself). <name>.localhost is 127.0.0.1 on the Mac, where the Catzoid proxies answer
//     (DevCatz's https://rustfs.localhost, DoCatz's <name>.docatz.localhost); hostIP takes a container to the same place.
//   - bare localhost: 127.0.0.1 / ::1 (RFC 6761), never asked upstream (the NAT's DNS refuses it).
func localAddrs(name string) (a, aaaa net.IP, ok bool) {
	name = strings.TrimSuffix(strings.ToLower(name), ".")
	switch {
	case name == "localhost":
		return net.IPv4(127, 0, 0, 1).To4(), net.IPv6loopback, true
	case hostNames[name] || strings.HasSuffix(name, ".localhost"):
		return net.ParseIP(hostIP).To4(), nil, true
	}
	return nil, nil, false
}

// localAnswer: our own answer for the names localAddrs knows; a type we have no address for gets an empty answer
// (NOERROR, no data), so a resolver asking AAAA first falls back to the A record.
func localAnswer(q []byte) []byte {
	if len(q) < 12 || binary.BigEndian.Uint16(q[4:6]) != 1 || q[2]&0x80 != 0 {
		return nil
	}
	name, end, ok := readName(q, 12)
	if !ok || end+4 > len(q) {
		return nil
	}
	a, aaaa, ok := localAddrs(name)
	if !ok {
		return nil
	}
	qtype := binary.BigEndian.Uint16(q[end : end+2])
	qclass := binary.BigEndian.Uint16(q[end+2 : end+4])
	out := append([]byte(nil), q[:end+4]...)  // header + the question
	out[2] = 0x84 | (q[2] & 0x01)             // response, authoritative, RD copied
	out[3] = 0x80                             // RA, NOERROR
	binary.BigEndian.PutUint16(out[6:8], 0)   // answers
	binary.BigEndian.PutUint16(out[8:10], 0)  // authority
	binary.BigEndian.PutUint16(out[10:12], 0) // additional
	var ip net.IP
	switch {
	case qclass != 1:
	case qtype == 1:
		ip = a
	case qtype == 28:
		ip = aaaa
	}
	if ip != nil {
		binary.BigEndian.PutUint16(out[6:8], 1)
		out = append(out, 0xc0, 12) // the name: a pointer to the question
		out = binary.BigEndian.AppendUint16(out, qtype)
		out = binary.BigEndian.AppendUint16(out, 1)
		out = binary.BigEndian.AppendUint32(out, 60)
		out = binary.BigEndian.AppendUint16(out, uint16(len(ip)))
		out = append(out, ip...)
	}
	return out
}

func readName(b []byte, off int) (string, int, bool) {
	var parts []string
	for off < len(b) {
		n := int(b[off])
		if n == 0 {
			return strings.Join(parts, "."), off + 1, true
		}
		if n&0xc0 != 0 || off+1+n > len(b) { // a question never compresses its name
			return "", 0, false
		}
		parts = append(parts, string(b[off+1:off+1+n]))
		off += 1 + n
	}
	return "", 0, false
}

func servfail(q []byte) []byte {
	if len(q) < 12 {
		return nil
	}
	out := append([]byte(nil), q...)
	out[2] = 0x80 | (q[2] & 0x01)
	out[3] = 0x82 // RA, SERVFAIL
	return out
}

// upstreams: the guest's own nameservers (DHCP from the Mac's NAT), read each time so a new lease counts at once.
func upstreams() []string {
	b, _ := os.ReadFile("/etc/resolv.conf")
	var out []string
	for _, line := range strings.Split(string(b), "\n") {
		f := strings.Fields(line)
		if len(f) >= 2 && f[0] == "nameserver" && f[1] != dnsIP {
			out = append(out, f[1])
		}
	}
	return out
}

func ask(ns string, q []byte, network string) []byte {
	c, err := net.DialTimeout(network, net.JoinHostPort(ns, "53"), 3*time.Second)
	if err != nil {
		return nil
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	if network == "tcp" {
		out := make([]byte, 2+len(q))
		binary.BigEndian.PutUint16(out, uint16(len(q)))
		copy(out[2:], q)
		if _, err := c.Write(out); err != nil {
			return nil
		}
		var n uint16
		if binary.Read(c, binary.BigEndian, &n) != nil {
			return nil
		}
		a := make([]byte, n)
		if _, err := io.ReadFull(c, a); err != nil {
			return nil
		}
		return a
	}
	if _, err := c.Write(q); err != nil {
		return nil
	}
	a := make([]byte, 65535)
	n, err := c.Read(a)
	if err != nil {
		return nil
	}
	return a[:n]
}

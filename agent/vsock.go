package main

import (
	"fmt"
	"net"
	"os"
	"time"

	"golang.org/x/sys/unix"
)

// A vsock listener (AF_VSOCK, any CID) wrapped as a net.Listener; its connections are net.Conn.

type vsockListener struct {
	fd   int
	port uint32
}

func listenVsock(port uint32) (net.Listener, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("socket: %w", err)
	}
	if err := unix.Bind(fd, &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: port}); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("bind: %w", err)
	}
	if err := unix.Listen(fd, 128); err != nil {
		unix.Close(fd)
		return nil, fmt.Errorf("listen: %w", err)
	}
	return &vsockListener{fd: fd, port: port}, nil
}

func (l *vsockListener) Accept() (net.Conn, error) {
	for {
		nfd, _, err := unix.Accept4(l.fd, unix.SOCK_CLOEXEC|unix.SOCK_NONBLOCK)
		if err == unix.EINTR {
			continue
		}
		if err != nil {
			return nil, err
		}
		return &vsockConn{f: os.NewFile(uintptr(nfd), fmt.Sprintf("vsock:%d", l.port)), fd: nfd, port: l.port}, nil
	}
}

func (l *vsockListener) Close() error   { return unix.Close(l.fd) }
func (l *vsockListener) Addr() net.Addr { return vsockAddr(l.port) }

type vsockAddr uint32

func (a vsockAddr) Network() string { return "vsock" }
func (a vsockAddr) String() string  { return fmt.Sprintf("vsock:%d", uint32(a)) }

type vsockConn struct {
	f    *os.File
	fd   int
	port uint32
}

func (c *vsockConn) Read(b []byte) (int, error)         { return c.f.Read(b) }
func (c *vsockConn) Write(b []byte) (int, error)        { return c.f.Write(b) }
func (c *vsockConn) Close() error                       { return c.f.Close() }
func (c *vsockConn) CloseWrite() error                  { return unix.Shutdown(c.fd, unix.SHUT_WR) }
func (c *vsockConn) LocalAddr() net.Addr                { return vsockAddr(c.port) }
func (c *vsockConn) RemoteAddr() net.Addr               { return vsockAddr(0) }
func (c *vsockConn) SetDeadline(t time.Time) error      { return c.f.SetDeadline(t) }
func (c *vsockConn) SetReadDeadline(t time.Time) error  { return c.f.SetReadDeadline(t) }
func (c *vsockConn) SetWriteDeadline(t time.Time) error { return c.f.SetWriteDeadline(t) }

func dialVsock(cid, port uint32) (net.Conn, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	if err := unix.Connect(fd, &unix.SockaddrVM{CID: cid, Port: port}); err != nil {
		unix.Close(fd)
		return nil, err
	}
	if err := unix.SetNonblock(fd, true); err != nil {
		unix.Close(fd)
		return nil, err
	}
	return &vsockConn{f: os.NewFile(uintptr(fd), fmt.Sprintf("vsock:%d", port)), fd: fd, port: port}, nil
}

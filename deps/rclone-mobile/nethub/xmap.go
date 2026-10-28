package nethub

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// MARK: - Transparent forwarding for proot's xnet extension (Android)
//
// iSH hands a guest connect() to the SOCKS entry from inside its kernel.
// proot only sees system calls, so its xnet extension (deps/proot
// src/extension/xnet) rewrites a hooked connect() to this listener instead,
// and once the connection has a local port it writes the original
// destination to <dir>/<local port>. Here that file is read (and removed),
// the destination is routed for the shell's tag with Decide - so the policy
// stays in one place - and the bytes are relayed.
//
// Nothing here guesses: a connection whose file does not appear in time is
// closed (proot only redirects a connect() after its own probe of this
// listener succeeded, so that is a lost write, not normal operation). A
// connection from anywhere but loopback is refused.
//
// [FEAT-261021-23] Stage 2 (UDP and DNS, iSH's c7fcfb037 on Android):
//   - a destination file may say "dns": the guest was connecting to its own
//     resolver's port 53, so the connection is answered as DNS over TCP by
//     dns.go (MagicDNS names through the node, the rest from the resolver);
//   - a connect()ed UDP socket is redirected to the UDP listener here. Its
//     file is "u<local port>" (the TCP and UDP port spaces overlap). Each
//     datagram from that port goes to the destination, routed by
//     dialUDPRoute exactly as a SOCKS association's would be, and replies
//     come back from the listener, raw: proot rewrites the source the guest
//     sees. A "dns" UDP file is answered query by query by dns.go. proot
//     sends unconnected datagrams (sendto) through a SOCKS UDP association
//     instead, as iSH does: udp.go.

const (
	xmapWait      = 3 * time.Second  // how long a connection waits for its destination file
	xmapStaleFile = 10 * time.Second // files older than this are swept
)

// XMap is the listener behind proot's xnet extension.
type XMap struct {
	hub *Hub
	dir string
	tag string

	mu       sync.Mutex
	ln4, ln6 net.Listener
	udp      *net.UDPConn
	stop     chan struct{}

	conns, failures atomic.Int64
	seq             atomic.Uint32

	umu      sync.Mutex
	sessions map[int]*xudpSession // by the guest socket's local port
	ucnt     xudpCounters
}

// NewXMap: connections are routed as `tag` (the shell's scope); `dir` is
// the owner-only directory proot writes destinations to.
func NewXMap(h *Hub, dir, tag string) *XMap {
	return &XMap{hub: h, dir: dir, tag: tag}
}

// Start listens on 127.0.0.1 and ::1 (the latter is optional: an IPv6-only
// failure leaves port6 0 and proot then uses the IPv4-mapped port4). It is
// idempotent: a running listener keeps its ports.
func (x *XMap) Start() (port4, port6 int, err error) {
	x.mu.Lock()
	defer x.mu.Unlock()
	if x.ln4 != nil {
		return portOf(x.ln4), portOf(x.ln6), nil
	}
	if err := os.MkdirAll(x.dir, 0o700); err != nil {
		return 0, 0, err
	}
	x.sweep(0) // destinations from an earlier process are meaningless
	ln4, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return 0, 0, err
	}
	ln6, err6 := net.Listen("tcp6", "[::1]:0")
	if err6 != nil {
		ln6 = nil
	}
	udp, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		ln4.Close()
		if ln6 != nil {
			ln6.Close()
		}
		return 0, 0, err
	}
	x.ln4, x.ln6, x.udp = ln4, ln6, udp
	x.stop = make(chan struct{})
	go x.serve(ln4)
	if ln6 != nil {
		go x.serve(ln6)
	}
	go x.serveUDP(udp, x.stop)
	go x.sweeper(x.stop)
	x.hub.logf("[Net][Xparent] listening on %s%s, udp %s (map %s, tag %s)", ln4.Addr(), func() string {
		if ln6 != nil {
			return " and " + ln6.Addr().String()
		}
		return ""
	}(), udp.LocalAddr(), filepath.Base(x.dir), x.tag)
	return portOf(ln4), portOf(ln6), nil
}

// Stop closes the listeners; connections being relayed finish on their own.
func (x *XMap) Stop() {
	x.mu.Lock()
	defer x.mu.Unlock()
	if x.ln4 == nil {
		return
	}
	close(x.stop)
	x.ln4.Close()
	if x.ln6 != nil {
		x.ln6.Close()
	}
	x.udp.Close()
	x.ln4, x.ln6, x.udp = nil, nil, nil
	x.closeSessions("stopped")
	x.sweep(0)
	x.hub.logf("[Net][Xparent] stopped")
}

// Ports reports the listening ports (0, 0 when stopped).
func (x *XMap) Ports() (int, int) {
	x.mu.Lock()
	defer x.mu.Unlock()
	return portOf(x.ln4), portOf(x.ln6)
}

// UDPPort is the UDP listener's port (0 when stopped).
func (x *XMap) UDPPort() int {
	x.mu.Lock()
	defer x.mu.Unlock()
	if x.udp == nil {
		return 0
	}
	return x.udp.LocalAddr().(*net.UDPAddr).Port
}

// Stats: connections handled and failed since the process started.
func (x *XMap) Stats() (conns, failures int64) { return x.conns.Load(), x.failures.Load() }

func portOf(ln net.Listener) int {
	if ln == nil {
		return 0
	}
	if a, ok := ln.Addr().(*net.TCPAddr); ok {
		return a.Port
	}
	return 0
}

func (x *XMap) serve(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go x.handle(c)
	}
}

func (x *XMap) handle(c net.Conn) {
	defer c.Close()
	ra, ok := c.RemoteAddr().(*net.TCPAddr)
	if !ok || !ra.IP.IsLoopback() {
		x.hub.logf("[Net][Xparent] refused a connection from %v (not loopback)", c.RemoteAddr())
		return
	}
	id := fmt.Sprintf("m%04x", x.seq.Add(1)&0xffff)
	dest, err := x.destination(c, ra.Port)
	if err == errXMapProbe {
		return // proot's liveness probe: connected and closed, nothing to route
	}
	if err != nil {
		x.failures.Add(1)
		x.hub.logf("[Net][Xparent] %s local port %d: %v - closed", id, ra.Port, err)
		return
	}
	if dest.clientID != "" {
		id += "~" + dest.clientID
	}
	h := x.hub
	addr := dest.addr
	if dest.dns {
		h.logf("[Net][Xparent] %s tcp dns resolver=%s", id, addr)
		x.conns.Add(1)
		h.dnsOverTCP(c, id+"~dns", x.tag, addr)
		return
	}
	host, _, _ := net.SplitHostPort(addr)
	d := h.Decide(x.tag, host)
	if h.policyLog.allow("x|" + x.tag + "|" + addr + "|" + d.Exit()) {
		h.logf("[Net][Xparent] %s tag=%s host=%s rule=%s route=%s exit=%s", id, x.tag, addr, d.Rule, d.Route, d.Exit())
	}
	ctx, cancel := context.WithTimeout(context.Background(), connectDeadline)
	t0 := time.Now()
	out, err := h.dial(ctx, d, addr)
	cancel()
	ms := time.Since(t0).Milliseconds()
	x.conns.Add(1)
	h.recordExit(d, err)
	if err != nil {
		x.failures.Add(1)
		h.logFailure(id, x.tag, addr, d, ms, err)
		return // the guest sees the connection closed
	}
	defer out.Close()
	if h.okLog.allow("x|" + d.Exit() + "|" + addr) {
		h.logSuccess(id, addr, d, ms)
	}
	h.active.Add(1)
	pipe(c, out)
	h.active.Add(-1)
}

var errXMapProbe = fmt.Errorf("closed without data (a probe)")

// xmapDest is one destination file: where the guest was connecting, its
// client id (proot's x<n>) and whether it was its resolver's DNS port.
type xmapDest struct {
	addr, clientID string
	dns            bool
}

// destination waits for proot's file for this local port, reads and removes
// it. A peer that closes without sending anything while no file exists is
// proot's liveness probe, not a lost destination (errXMapProbe).
func (x *XMap) destination(c net.Conn, localPort int) (xmapDest, error) {
	path := filepath.Join(x.dir, strconv.Itoa(localPort))
	deadline := time.Now().Add(xmapWait)
	wait := 2 * time.Millisecond
	for {
		data, rerr := os.ReadFile(path)
		if rerr == nil {
			os.Remove(path)
			return parseXMapFile(string(data))
		}
		if peerClosedWithoutData(c) {
			return xmapDest{}, errXMapProbe
		}
		if time.Now().After(deadline) {
			return xmapDest{}, fmt.Errorf("no destination written within %v", xmapWait)
		}
		time.Sleep(wait)
		if wait < 50*time.Millisecond {
			wait *= 2
		}
	}
}

// parseXMapFile reads "dst <ip> <port>", an optional "id <client id>" and
// an optional "dns" (the guest's resolver, port 53).
func parseXMapFile(s string) (xmapDest, error) {
	var d xmapDest
	sc := bufio.NewScanner(strings.NewReader(s))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		switch {
		case len(f) == 3 && f[0] == "dst":
			ip := net.ParseIP(f[1])
			port, perr := strconv.Atoi(f[2])
			if ip == nil || perr != nil || port <= 0 || port > 65535 {
				return xmapDest{}, fmt.Errorf("bad destination %q", sc.Text())
			}
			d.addr = net.JoinHostPort(ip.String(), f[2])
		case len(f) == 2 && f[0] == "id":
			d.clientID = f[1]
		case len(f) == 1 && f[0] == "dns":
			d.dns = true
		}
	}
	if d.addr == "" {
		return xmapDest{}, fmt.Errorf("no destination in the file")
	}
	return d, nil
}

func (x *XMap) sweeper(stop chan struct{}) {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			x.sweep(xmapStaleFile)
			x.sweepSessions()
		}
	}
}

// sweep removes destination files older than maxAge (0 = all). A UDP
// socket's "u<port>" file lives as long as the socket (proot removes it on
// close), so only a full sweep removes those.
func (x *XMap) sweep(maxAge time.Duration) {
	entries, err := os.ReadDir(x.dir)
	if err != nil {
		return
	}
	now := time.Now()
	for _, e := range entries {
		info, err := e.Info()
		if err != nil || info.IsDir() {
			continue
		}
		if maxAge != 0 && strings.HasPrefix(e.Name(), "u") {
			continue
		}
		if maxAge == 0 || now.Sub(info.ModTime()) > maxAge {
			os.Remove(filepath.Join(x.dir, e.Name()))
		}
	}
}

// peerClosedWithoutData peeks (never consumes) at the socket: true once the
// peer has closed and nothing is buffered.
func peerClosedWithoutData(c net.Conn) bool {
	sc, ok := c.(syscall.Conn)
	if !ok {
		return false
	}
	rc, err := sc.SyscallConn()
	if err != nil {
		return false
	}
	closed := false
	buf := make([]byte, 1)
	rc.Read(func(fd uintptr) bool {
		n, _, rerr := syscall.Recvfrom(int(fd), buf, syscall.MSG_PEEK|syscall.MSG_DONTWAIT)
		closed = n == 0 && rerr == nil
		return true // never block
	})
	return closed
}

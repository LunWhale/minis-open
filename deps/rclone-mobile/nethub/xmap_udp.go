package nethub

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"time"
)

// MARK: - UDP for proot's xnet extension (Android, FEAT-261021-23)
//
// A guest UDP socket that connect()s to a hooked destination is connected to
// this listener instead (see xmap.go), and proot writes the destination to
// <dir>/u<local port> before the guest gets control back. The guest then
// uses the socket as it would have - send/write/recv/read - and nothing in
// its datagrams changes: each one from that port is sent on to the
// destination, and what comes back is sent to the port from here (proot
// tells the guest it came from the destination).
//
// One session per guest port: the routed socket to the destination (or, for
// "dns", the resolver answering each query), closed when idle. A datagram
// from a port without a file is dropped and counted: nothing on the device
// but proot's redirected sockets is served.

const (
	xudpFileWait    = 500 * time.Millisecond // proot writes the file before the guest can send
	maxXUDPSessions = 256
)

// XMapUDPStats are the UDP map's counters, for the status export.
type XMapUDPStats struct {
	Active   int64 `json:"active"`   // sessions open now
	Opened   int64 `json:"opened"`   // since start
	Sent     int64 `json:"sent"`     // datagrams from guests
	Received int64 `json:"received"` // datagrams back to guests
	Unmapped int64 `json:"unmapped"` // dropped: no destination file for the port
	Failed   int64 `json:"failed"`   // a destination could not be opened
	DNS      int64 `json:"dns"`      // queries answered as DNS
}

type xudpCounters struct {
	active, opened, sent, received, unmapped, failed, dns atomic.Int64
}

type xudpSession struct {
	x      *XMap
	id     string
	port   int // the guest socket's local port
	client *net.UDPAddr
	dest   xmapDest
	conn   net.Conn // to the destination; nil for dns
	idle   time.Duration

	lastUsed atomic.Int64 // unix nano
	closed   atomic.Bool
}

func (x *XMap) ucount() *xudpCounters { return &x.ucnt }

// UDPStats reports the UDP map's counters.
func (x *XMap) UDPStats() XMapUDPStats {
	c := x.ucount()
	return XMapUDPStats{Active: c.active.Load(), Opened: c.opened.Load(), Sent: c.sent.Load(),
		Received: c.received.Load(), Unmapped: c.unmapped.Load(), Failed: c.failed.Load(), DNS: c.dns.Load()}
}

func (x *XMap) serveUDP(ln *net.UDPConn, stop chan struct{}) {
	buf := make([]byte, udpMaxDatagram)
	for {
		n, src, err := ln.ReadFromUDP(buf)
		if err != nil {
			select {
			case <-stop:
			default:
				x.hub.logf("[Net][Xparent] udp listener: %v", err)
			}
			return
		}
		if !src.IP.IsLoopback() {
			continue
		}
		s := x.session(src)
		if s == nil {
			continue
		}
		s.lastUsed.Store(time.Now().UnixNano())
		data := append([]byte(nil), buf[:n]...)
		c := x.ucount()
		c.sent.Add(1)
		if s.dest.dns {
			c.dns.Add(1)
			go s.answer(ln, data)
			continue
		}
		if _, err := s.conn.Write(data); err != nil && x.hub.failLog.allow("xudp-write|"+s.dest.addr) {
			x.hub.logf("[Net][Dial] %s FAIL stage=udp-send target=%s class=%s tag=%s: %v", s.id, s.dest.addr, Classify(err), x.tag, err)
		}
	}
}

// session returns the open session for src's port, or opens one from its
// destination file; nil (datagram dropped) when there is none.
func (x *XMap) session(src *net.UDPAddr) *xudpSession {
	x.umu.Lock()
	if s := x.sessions[src.Port]; s != nil && !s.closed.Load() {
		x.umu.Unlock()
		return s
	}
	x.umu.Unlock()

	c := x.ucount()
	dest, err := x.udpDestination(src.Port)
	if err != nil {
		c.unmapped.Add(1)
		if x.hub.entryLog.allow("xudp-unmapped") {
			x.hub.logf("[Net][Xparent] udp from local port %d dropped: %v", src.Port, err)
		}
		return nil
	}
	id := fmt.Sprintf("u%04x", x.seq.Add(1)&0xffff)
	if dest.clientID != "" {
		id += "~" + dest.clientID
	}
	s := &xudpSession{x: x, id: id, port: src.Port, client: src, dest: dest, idle: udpIdle}
	if l := x.hub.udpLimits(); l.idle > 0 {
		s.idle = l.idle
	}
	if dest.dns {
		s.idle = x.hub.udpLimits().dnsIdle
		x.hub.logf("[Net][Xparent] %s udp dns resolver=%s", id, dest.addr)
	} else {
		host, _, _ := net.SplitHostPort(dest.addr)
		conn, _, _, err := x.hub.dialUDPRoute(id, x.tag, dest.addr, host)
		if err != nil {
			c.failed.Add(1)
			return nil // logged by dialUDPRoute; the guest's datagram is lost, as on a bad network
		}
		s.conn = conn
	}
	s.lastUsed.Store(time.Now().UnixNano())

	var victim *xudpSession
	x.umu.Lock()
	if x.sessions == nil {
		x.sessions = map[int]*xudpSession{}
	}
	if old := x.sessions[src.Port]; old != nil && !old.closed.Load() { // another datagram won the race
		x.umu.Unlock()
		s.close("")
		return old
	}
	if len(x.sessions) >= maxXUDPSessions {
		for _, o := range x.sessions {
			if victim == nil || o.lastUsed.Load() < victim.lastUsed.Load() {
				victim = o
			}
		}
		delete(x.sessions, victim.port)
	}
	x.sessions[src.Port] = s
	x.umu.Unlock()
	c.active.Add(1)
	c.opened.Add(1)
	if victim != nil {
		victim.close("evicted (session limit)")
	}
	if s.conn != nil {
		x.mu.Lock()
		ln := x.udp
		x.mu.Unlock()
		if ln != nil {
			go s.readBack(ln)
		}
	}
	return s
}

// udpDestination reads (and keeps: the socket may send many datagrams, and
// again after its session went idle) the file proot wrote for this port.
func (x *XMap) udpDestination(port int) (xmapDest, error) {
	path := filepath.Join(x.dir, "u"+strconv.Itoa(port))
	deadline := time.Now().Add(xudpFileWait)
	wait := 2 * time.Millisecond
	for {
		data, err := os.ReadFile(path)
		if err == nil {
			return parseXMapFile(string(data))
		}
		if time.Now().After(deadline) {
			return xmapDest{}, fmt.Errorf("no destination file")
		}
		time.Sleep(wait)
		if wait < 50*time.Millisecond {
			wait *= 2
		}
	}
}

// readBack relays what the destination sends to the guest's port.
func (s *xudpSession) readBack(ln *net.UDPConn) {
	buf := make([]byte, udpMaxDatagram)
	for {
		n, err := s.conn.Read(buf)
		if err != nil {
			return
		}
		s.lastUsed.Store(time.Now().UnixNano())
		if _, err := ln.WriteToUDP(buf[:n], s.client); err != nil {
			return
		}
		s.x.ucount().received.Add(1)
	}
}

// answer answers one DNS query as the guest's resolver would, through
// dns.go's rules; no answer means none is sent (the guest retries).
func (s *xudpSession) answer(ln *net.UDPConn, query []byte) {
	var none *net.Conn
	answer, err := s.x.hub.answerDNS(s.id, s.x.tag, s.dest.addr, query, false, none)
	if err != nil {
		return
	}
	if _, err := ln.WriteToUDP(answer, s.client); err == nil {
		s.x.ucount().received.Add(1)
	}
}

func (s *xudpSession) close(reason string) {
	if s.closed.Swap(true) {
		return
	}
	if s.conn != nil {
		s.conn.Close()
	}
	if reason == "" {
		return // a duplicate that never served
	}
	// The file stays: the guest socket may send again after a quiet spell
	// and then opens a new session. proot removes it when the socket is
	// closed; Start and Stop sweep them all.
	s.x.ucount().active.Add(-1)
	if s.x.hub.entryLog.allow("xudp-close|" + reason) {
		s.x.hub.logf("[Net][Xparent] %s udp session closed reason=%s", s.id, reason)
	}
}

// sweepSessions closes sessions idle for longer than their idle time.
func (x *XMap) sweepSessions() {
	now := time.Now()
	x.umu.Lock()
	var idle []*xudpSession
	for p, s := range x.sessions {
		if s.closed.Load() || now.Sub(time.Unix(0, s.lastUsed.Load())) > s.idle {
			idle = append(idle, s)
			delete(x.sessions, p)
		}
	}
	x.umu.Unlock()
	for _, s := range idle {
		s.close("idle")
	}
}

func (x *XMap) closeSessions(reason string) {
	x.umu.Lock()
	all := x.sessions
	x.sessions = nil
	x.umu.Unlock()
	for _, s := range all {
		s.close(reason)
	}
}

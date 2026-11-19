package nethub

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"net/netip"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// MARK: - SOCKS5 UDP ASSOCIATE (RFC 1928 section 7)
//
// iSH's transparent forwarding (deps/ish fs/xnet.h) wraps a hooked guest
// datagram in the SOCKS5 UDP header and sends it, from the guest's own
// socket, to the relay this file opens. Each association:
//
//   - is tied to its control connection: when that closes, the association
//     ends; when the association ends here (idle, over the limit), the
//     control connection is closed, and iSH opens a new one on its next
//     datagram;
//   - takes datagrams only from the client address declared in the request
//     (127.0.0.1:<the guest socket's port>); anything else is dropped and
//     counted, so another app on the device cannot use the relay;
//   - routes each destination with Decide for the association's tag, as a
//     TCP connection would be: the tailnet (tsnet's UDP, including an exit
//     node), or directly. A proxy route cannot carry UDP (HTTP upstreams),
//     so there non-tailnet datagrams go directly and are logged as
//     udp-direct(proxy-route);
//   - keeps one connected socket per destination (a "flow"), closed after
//     an idle time; at most maxUDPFlows of them, the least recently used
//     goes first.
//
// A "~dns" association carries DNS queries to the guest's resolver; see
// dns.go.

const (
	cmdUDPAssociate = 3

	udpIdle         = 120 * time.Second
	udpDNSIdle      = 30 * time.Second
	maxAssociations = 256
	maxUDPFlows     = 64
	udpMaxDatagram  = 65535
)

// UDPStats are the hub's UDP counters, for the status export and diagnose.
type UDPStats struct {
	Active       int64 `json:"active"`       // associations open now
	Opened       int64 `json:"opened"`       // since start
	Evicted      int64 `json:"evicted"`      // ended because maxAssociations was reached
	Flows        int64 `json:"flows"`        // destinations open now
	Sent         int64 `json:"sent"`         // datagrams from guests to destinations
	Received     int64 `json:"received"`     // datagrams back to guests
	Spoofed      int64 `json:"spoofed"`      // dropped: not from the declared client
	Malformed    int64 `json:"malformed"`    // dropped: bad header or fragment
	DialFailures int64 `json:"dialFailures"` // a destination could not be opened
	DNSQueries   int64 `json:"dnsQueries"`   // intercepted queries (UDP and TCP)
	DNSTailnet   int64 `json:"dnsTailnet"`   // of those, answered by the node's resolver
	DNSFailures  int64 `json:"dnsFailures"`  // no answer could be had
}

type udpCounters struct {
	active, opened, evicted, flows, sent, received, spoofed, malformed,
	dialFailures, dnsQueries, dnsTailnet, dnsFailures atomic.Int64
}

func (h *Hub) UDPStats() UDPStats {
	c := &h.udp
	return UDPStats{Active: c.active.Load(), Opened: c.opened.Load(), Evicted: c.evicted.Load(),
		Flows: c.flows.Load(), Sent: c.sent.Load(), Received: c.received.Load(), Spoofed: c.spoofed.Load(),
		Malformed: c.malformed.Load(), DialFailures: c.dialFailures.Load(), DNSQueries: c.dnsQueries.Load(),
		DNSTailnet: c.dnsTailnet.Load(), DNSFailures: c.dnsFailures.Load()}
}

// udpLimits are constants, kept on the hub so tests can shrink them.
type udpLimits struct {
	idle, dnsIdle time.Duration
	assocs, flows int
	sweep         time.Duration
}

func defaultUDPLimits() udpLimits {
	return udpLimits{idle: udpIdle, dnsIdle: udpDNSIdle, assocs: maxAssociations, flows: maxUDPFlows, sweep: 5 * time.Second}
}

type udpAssoc struct {
	h      *Hub
	id     string
	tag    string
	dns    bool
	ctl    net.Conn
	relay  *net.UDPConn
	client netip.AddrPort // declared source; port 0 = the first loopback sender
	idle   time.Duration

	mu       sync.Mutex
	flows    map[string]*udpFlow
	lastUsed time.Time
	closed   bool
	reason   string
	sent     int64
	received int64
}

type udpFlow struct {
	dst      string // as the guest named it, "host:port"
	header   []byte // the SOCKS UDP header replies carry
	conn     net.Conn
	lastUsed atomic.Int64 // unix nano
}

// serveAssociate runs one association until its control connection or the
// association ends. host:port is the client address of the request.
func (h *Hub) serveAssociate(c net.Conn, id, tag string, dns bool, host string, port int) {
	client, err := declaredClient(c, host, port)
	if err != nil {
		writeReply(c, repNotAllowed)
		h.logf("[Net][Entry] %s udp associate refused: %v", id, err)
		return
	}
	relay, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		writeReply(c, repGeneralFail)
		h.logf("[Net][Entry] %s udp associate failed: relay: %v", id, err)
		return
	}
	limits := h.udpLimits()
	a := &udpAssoc{h: h, id: id, tag: tag, dns: dns, ctl: c, relay: relay, client: client,
		idle: limits.idle, flows: map[string]*udpFlow{}, lastUsed: time.Now()}
	if dns {
		a.idle = limits.dnsIdle
	}
	h.addAssoc(a, limits.assocs)
	rp := relay.LocalAddr().(*net.UDPAddr).Port
	reply := []byte{socksVer, repSuccess, 0, atypIPv4, 127, 0, 0, 1, byte(rp >> 8), byte(rp)}
	if _, err := c.Write(reply); err != nil {
		a.close("client")
		return
	}
	kind := "udp"
	if dns {
		kind = "dns"
	}
	h.logf("[Net][Entry] %s %s association open tag=%s client=%s", id, kind, tag, client)
	go a.readRelay()
	go a.sweeper(limits.sweep)
	// The control connection carries nothing more; EOF ends the association.
	io.Copy(io.Discard, c)
	a.close("client")
}

// declaredClient: the request names where the datagrams will come from. iSH
// declares 127.0.0.1:<port>; an unspecified address means the control
// connection's own address, port 0 "whatever sends first". Only loopback
// clients are served (the entry is a loopback service).
func declaredClient(c net.Conn, host string, port int) (netip.AddrPort, error) {
	ra, _ := c.RemoteAddr().(*net.TCPAddr)
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return netip.AddrPort{}, errors.New("client address must be an IP")
	}
	ip = ip.Unmap()
	if ip.IsUnspecified() && ra != nil {
		ip, _ = netip.AddrFromSlice(ra.IP)
		ip = ip.Unmap()
	}
	if !ip.IsLoopback() {
		return netip.AddrPort{}, errors.New("client " + ip.String() + " is not on the loopback")
	}
	return netip.AddrPortFrom(ip, uint16(port)), nil
}

func (h *Hub) udpLimits() udpLimits {
	h.mu.RLock()
	defer h.mu.RUnlock()
	if h.udpLimit.assocs == 0 {
		return defaultUDPLimits()
	}
	return h.udpLimit
}

// addAssoc registers a, ending the least recently used association first
// when the limit is reached.
func (h *Hub) addAssoc(a *udpAssoc, limit int) {
	var victim *udpAssoc
	h.assocMu.Lock()
	if h.assocs == nil {
		h.assocs = map[*udpAssoc]struct{}{}
	}
	if len(h.assocs) >= limit {
		var oldest time.Time
		for o := range h.assocs {
			if t := o.used(); victim == nil || t.Before(oldest) {
				victim, oldest = o, t
			}
		}
	}
	h.assocs[a] = struct{}{}
	h.assocMu.Unlock()
	h.udp.active.Add(1)
	h.udp.opened.Add(1)
	if victim != nil {
		h.udp.evicted.Add(1)
		victim.close("evicted (association limit)")
	}
}

func (a *udpAssoc) used() time.Time {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.lastUsed
}

func (a *udpAssoc) touch() {
	a.mu.Lock()
	a.lastUsed = time.Now()
	a.mu.Unlock()
}

func (a *udpAssoc) close(reason string) {
	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		return
	}
	a.closed = true
	a.reason = reason
	flows := a.flows
	a.flows = map[string]*udpFlow{}
	sent, received := a.sent, a.received
	a.mu.Unlock()
	a.ctl.Close()
	a.relay.Close()
	for _, f := range flows {
		f.conn.Close()
		a.h.udp.flows.Add(-1)
	}
	h := a.h
	h.assocMu.Lock()
	delete(h.assocs, a)
	h.assocMu.Unlock()
	h.udp.active.Add(-1)
	h.logf("[Net][Entry] %s association closed reason=%s sent=%d received=%d", a.id, reason, sent, received)
}

func (a *udpAssoc) isClosed() bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.closed
}

// sweeper closes idle flows, and the association once nothing has used it
// for its idle time.
func (a *udpAssoc) sweeper(every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for range t.C {
		if a.isClosed() {
			return
		}
		now := time.Now()
		a.mu.Lock()
		for k, f := range a.flows {
			if now.Sub(time.Unix(0, f.lastUsed.Load())) > a.flowIdle(f.dst) {
				f.conn.Close()
				delete(a.flows, k)
				a.h.udp.flows.Add(-1)
			}
		}
		idle := now.Sub(a.lastUsed) > a.idle
		a.mu.Unlock()
		if idle {
			a.close("idle")
			return
		}
	}
}

// DNS flows go quiet after one answer: they get the short idle time.
func (a *udpAssoc) flowIdle(dst string) time.Duration {
	if _, port, err := net.SplitHostPort(dst); err == nil && port == "53" {
		return a.h.udpLimits().dnsIdle
	}
	return a.idle
}

// readRelay takes the client's datagrams off the relay socket.
func (a *udpAssoc) readRelay() {
	buf := make([]byte, udpMaxDatagram+64)
	for {
		n, src, err := a.relay.ReadFromUDPAddrPort(buf)
		if err != nil {
			a.close("relay closed")
			return
		}
		src = netip.AddrPortFrom(src.Addr().Unmap(), src.Port())
		if !a.accepts(src) {
			a.h.udp.spoofed.Add(1)
			if a.h.entryLog.allow("udp-spoof:" + a.id) {
				a.h.logf("[Net][Entry] %s dropped a datagram from %s: not the declared client %s", a.id, src, a.client)
			}
			continue
		}
		host, port, payload, err := parseUDPHeader(buf[:n])
		if err != nil {
			a.h.udp.malformed.Add(1)
			if a.h.entryLog.allow("udp-bad:" + a.id) {
				a.h.logf("[Net][Entry] %s dropped a datagram: %v", a.id, err)
			}
			continue
		}
		a.touch()
		dst := net.JoinHostPort(host, strconv.Itoa(port))
		data := append([]byte(nil), payload...)
		hdr := append([]byte(nil), buf[:n-len(payload)]...)
		if a.dns {
			go a.h.answerUDPDNS(a, dst, hdr, data)
			continue
		}
		a.forward(dst, host, hdr, data)
	}
}

func (a *udpAssoc) accepts(src netip.AddrPort) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if src.Addr() != a.client.Addr() {
		return false
	}
	if a.client.Port() == 0 {
		a.client = src // RFC 1928: the first datagram fixes an unknown port
		return true
	}
	return src.Port() == a.client.Port()
}

// forward sends one datagram to dst, opening its flow first if needed.
func (a *udpAssoc) forward(dst, host string, hdr, payload []byte) {
	f, err := a.flow(dst, host, hdr)
	if err != nil {
		return // logged by flow
	}
	f.lastUsed.Store(time.Now().UnixNano())
	if _, err := f.conn.Write(payload); err != nil {
		if a.h.failLog.allow("udp-write|" + dst) {
			a.h.logf("[Net][Dial] %s FAIL stage=udp-send target=%s class=%s tag=%s: %v", a.id, dst, Classify(err), a.tag, err)
		}
		return
	}
	a.h.udp.sent.Add(1)
	a.mu.Lock()
	a.sent++
	a.mu.Unlock()
}

func (a *udpAssoc) flow(dst, host string, hdr []byte) (*udpFlow, error) {
	a.mu.Lock()
	if f := a.flows[dst]; f != nil {
		a.mu.Unlock()
		return f, nil
	}
	a.mu.Unlock()

	h := a.h
	conn, d, ms, err := h.dialUDPRoute(a.id, a.tag, dst, host)
	if err != nil {
		return nil, err
	}
	f := &udpFlow{dst: dst, header: hdr, conn: conn}
	f.lastUsed.Store(time.Now().UnixNano())

	a.mu.Lock()
	if a.closed {
		a.mu.Unlock()
		conn.Close()
		return nil, net.ErrClosed
	}
	if old := a.flows[dst]; old != nil { // another datagram won the race
		a.mu.Unlock()
		conn.Close()
		return old, nil
	}
	var victim *udpFlow
	if limit := h.udpLimits().flows; len(a.flows) >= limit {
		for _, o := range a.flows {
			if victim == nil || o.lastUsed.Load() < victim.lastUsed.Load() {
				victim = o
			}
		}
		delete(a.flows, victim.dst)
	}
	a.flows[dst] = f
	a.mu.Unlock()
	h.udp.flows.Add(1)
	if victim != nil {
		victim.conn.Close()
		h.udp.flows.Add(-1)
		if h.entryLog.allow("udp-flow-limit:" + a.id) {
			h.logf("[Net][Entry] %s closed the flow to %s: %d destinations is the limit", a.id, victim.dst, h.udpLimits().flows)
		}
	}
	if d.Kind == "tailscale" && h.okLog.allow("udp|"+d.Exit()+"|"+dst) {
		h.logf("[Net][Dial] %s ok udp tailnet target=%s in %dms peer=%s", a.id, dst, ms, orNone(h.describePeer(hostOf(dst))))
	}
	go a.readFlow(f)
	return f, nil
}

// dialUDPRoute opens a connected UDP socket to dst for tag, routed as a TCP
// connection would be - except that loopback is always this device and a
// proxy route cannot carry UDP (Q2: non-tailnet datagrams leave directly).
// Shared by SOCKS associations and proot's UDP map (xmap.go).
func (h *Hub) dialUDPRoute(id, tag, dst, host string) (net.Conn, Decision, int64, error) {
	d := h.Decide(tag, host)
	if ip, err := netip.ParseAddr(host); err == nil && ip.Unmap().IsLoopback() {
		// Never the tailnet or an exit node: it is this device.
		d = Decision{Kind: "direct", Route: d.Route, Rule: "loopback"}
	}
	if d.Kind == "proxy" {
		// An upstream proxy cannot carry UDP (Q2): only tailnet destinations
		// are relayed, the rest leaves directly, said so in the log.
		d = Decision{Kind: "direct", Route: d.Route, Rule: "udp-direct(proxy-route)"}
	}
	if h.policyLog.allow("udp|" + tag + "|" + dst + "|" + d.Exit()) {
		h.logf("[Net][Policy] %s udp tag=%s host=%s rule=%s route=%s exit=%s", id, tag, dst, d.Rule, d.Route, d.Exit())
	}
	ctx, cancel := context.WithTimeout(context.Background(), connectDeadline)
	t0 := time.Now()
	var conn net.Conn
	var err error
	if d.Kind == "tailscale" && h.exitOffline(d) {
		err = stageErr("udp-tailnet", errExitOffline)
	} else if d.Kind == "tailscale" {
		conn, err = h.ts.Dial(ctx, "udp", dst)
		err = stageErr("udp-tailnet", err)
	} else {
		conn, err = h.dialDirect(ctx, "udp", dst)
		err = stageErr("udp-direct", err)
	}
	cancel()
	ms := time.Since(t0).Milliseconds()
	h.recordExit(d, err)
	if err != nil {
		h.udp.dialFailures.Add(1)
		h.logFailure(id, tag, dst, d, ms, err)
		return nil, d, ms, err
	}
	return conn, d, ms, nil
}

// readFlow relays what a destination sends back to the client.
func (a *udpAssoc) readFlow(f *udpFlow) {
	buf := make([]byte, len(f.header)+udpMaxDatagram)
	copy(buf, f.header)
	for {
		n, err := f.conn.Read(buf[len(f.header):])
		if err != nil {
			return
		}
		f.lastUsed.Store(time.Now().UnixNano())
		if err := a.toClient(buf[:len(f.header)+n]); err != nil {
			return
		}
	}
}

func (a *udpAssoc) toClient(datagram []byte) error {
	a.mu.Lock()
	client := a.client
	a.mu.Unlock()
	if client.Port() == 0 {
		return nil // nothing to send to yet
	}
	if _, err := a.relay.WriteToUDPAddrPort(datagram, client); err != nil {
		return err
	}
	a.h.udp.received.Add(1)
	a.mu.Lock()
	a.received++
	a.lastUsed = time.Now()
	a.mu.Unlock()
	return nil
}

// parseUDPHeader splits RSV RSV FRAG ATYP DST.ADDR DST.PORT DATA.
// Fragmentation is not supported (RFC 1928 lets a server drop fragments).
func parseUDPHeader(b []byte) (host string, port int, payload []byte, err error) {
	if len(b) < 4 {
		return "", 0, nil, errors.New("short header")
	}
	if b[2] != 0 {
		return "", 0, nil, errors.New("fragment " + strconv.Itoa(int(b[2])) + " (fragments are not supported)")
	}
	rest := b[4:]
	switch b[3] {
	case atypIPv4:
		if len(rest) < 4+2 {
			return "", 0, nil, errors.New("short IPv4 header")
		}
		host, rest = net.IP(rest[:4]).String(), rest[4:]
	case atypIPv6:
		if len(rest) < 16+2 {
			return "", 0, nil, errors.New("short IPv6 header")
		}
		host, rest = net.IP(rest[:16]).String(), rest[16:]
	case atypDomain:
		if len(rest) < 1 || len(rest) < 1+int(rest[0])+2 {
			return "", 0, nil, errors.New("short domain header")
		}
		host, rest = string(rest[1:1+int(rest[0])]), rest[1+int(rest[0]):]
	default:
		return "", 0, nil, errors.New("unknown address type " + strconv.Itoa(int(b[3])))
	}
	return host, int(binary.BigEndian.Uint16(rest[:2])), rest[2:], nil
}

// udpHeader builds the header for a datagram from host:port.
func udpHeader(host string, port int) []byte {
	ip, err := netip.ParseAddr(host)
	if err != nil {
		h := []byte{0, 0, 0, atypDomain, byte(len(host))}
		h = append(h, host...)
		return append(h, byte(port>>8), byte(port))
	}
	ip = ip.Unmap()
	h := []byte{0, 0, 0, atypIPv4}
	if ip.Is6() {
		h[3] = atypIPv6
	}
	h = append(h, ip.AsSlice()...)
	return append(h, byte(port>>8), byte(port))
}
